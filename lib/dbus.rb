#!/usr/bin/ruby

require 'dbus/type'
require 'dbus/introspect'

require 'socket'
require 'thread'

module DBus

  BIG_END = ?B
  LIL_END = ?l

  if [0x01020304].pack("L").unpack("V")[0] == 0x01020304
    HOST_END = LIL_END
  else
    HOST_END = BIG_END
  end

  class InvalidPacketException < Exception
  end

  class TypeException < Exception
  end

  class NotImplementedException < Exception
  end

  class PacketUnmarshaller
    attr_reader :idx

    def initialize(buffer, endianness)
      @buffy, @endianness = buffer.dup, endianness
      if @endianness == BIG_END
        @uint32 = "N"
      elsif @endianness == LIL_END
        @uint32 = "V"
      else
        raise Exception, "Incorrect endianneess"
      end
      @idx = 0
    end

    def unmarshall(signature, len = nil)
      if len != nil
        if @buffy.size < @idx + len
          raise IncompleteBufferException
        end
      end
      sigtree = Type::Parser.new(signature).parse
      ret = Array.new
      sigtree.each do |elem|
        ret << do_parse(elem)
      end
      ret
    end

    def align4
      @idx = @idx + 3 & ~3
      raise IncompleteBufferException if @idx > @buffy.size
    end

    def align8
      @idx = @idx + 7 & ~7
      raise IncompleteBufferException if @idx > @buffy.size
    end

    private

    def get(nbytes)
      raise IncompleteBufferException if @idx + nbytes > @buffy.size
      ret = @buffy.slice(@idx, nbytes)
      @idx += nbytes
      ret
    end

    def get_nul_terminated
      if not @buffy[@idx..-1] =~ /^([^\0]*)\0/
        raise InvalidPacketException
      end
      str = $1
      raise IncompleteBufferException if @idx + str.size + 1 > @buffy.size
      @idx += str.size + 1
      str
    end

    def getstring
      align4
      str_sz = get(4).unpack(@uint32)[0]
      ret = @buffy.slice(@idx, str_sz)
      raise IncompleteBufferException if @idx + str_sz + 1 > @buffy.size
      @idx += str_sz
      if @buffy[@idx] != 0
        raise InvalidPacketException, "String is not nul-terminated"
      end
      @idx += 1
      # no exception, see check above
      ret
    end

    def getsignature
      str_sz = get(1).unpack('C')[0]
      ret = @buffy.slice(@idx, str_sz)
      raise IncompleteBufferException if @idx + str_sz + 1 >= @buffy.size
      @idx += str_sz
      if @buffy[@idx] != 0
        raise InvalidPacketException, "Type is not nul-terminated"
      end
      @idx += 1
      # no exception, see check above
      ret
    end

    def do_parse(signature)
      packet = nil
      case signature.sigtype
      when Type::BYTE
        packet = get(1).unpack("C")[0]
      when Type::UINT32
        align4
        packet = get(4).unpack(@uint32)[0]
      when Type::BOOLEAN
        align4
        v = get(4).unpack(@uint32)[0]
        raise InvalidPacketException if not [0, 1].member?(v)
        packet = (v == 1)
      when Type::ARRAY
        align4
        # checks please
        array_sz = get(4).unpack(@uint32)[0]
        raise InvalidPacketException if array_sz > 67108864
        packet = Array.new
        #align8
        # We should move to the alignement of the subtype, and THEN check for
        # the correcness of the size. Annoying.
        #arraydata = @buffy[@idx, array_sz]
        #puts "#{arraydata.size} #{array_sz}"
        #raise IncompleteBufferException if arraydata.size != array_sz
        start_idx = @idx
        while @idx - start_idx < array_sz
          packet << do_parse(signature.child)
        end
      when Type::STRUCT
        align8
        packet = Array.new
        signature.members.each do |elem|
          packet << do_parse(elem)
        end
      when Type::VARIANT
        string = get_nul_terminated
        # error checking please
        sig = Type::Parser.new(string).parse[0]
        packet = do_parse(sig)
      when Type::OBJECT_PATH
        packet = getstring
      when Type::STRING
        packet = getstring
      when Type::SIGNATURE
        packet = getsignature
      else
        raise NotImplementedException,
        	"sigtype: #{signature.sigtype} (#{signature.sigtype.chr})"
      end
      packet
    end
  end

  class PacketMarshaller
    attr_reader :packet
    def initialize
      @packet = ""
    end

    def align4
      @packet = @packet.ljust(@packet.length + 3 & ~3, 0.chr)
    end

    def align8
      @packet = @packet.ljust(@packet.length + 7 & ~7, 0.chr)
    end

    def dump
      p @packet
    end

    def setstring(str)
      ret = ""
      ret += [str.length].pack("L")
      ret += str + "\0"
      ret
    end

    def setsignature(str)
      ret = ""
      ret += str.length.chr
      ret += str + "\0"
      ret
    end

    def array
      sizeidx = @packet.size
      @packet += "ABCD"
      align8
      yield
      sz = @packet.size - sizeidx - 4
      raise InvalidPacketException if sz > 67108864
      @packet[sizeidx...sizeidx + 4] = [sz].pack("L")
    end

    def struct
      align8
      yield
    end

    def append_string(s)
      @packet += s + "\0"
    end

    def append(type, val)
      type = Type::Parser.new(type).parse if type.class == String
      case type
      when Type::BYTE
        @packet += val.chr
      when Type::UINT32
        align4
        @packet += [val].pack("L")
      when Type::BOOLEAN
        align4
        if val
          @packet += [1].pack("L")
        else
          @packet += [0].pack("L")
        end
      when Type::OBJECT_PATH
        @packet += setstring(val)
      when Type::STRING
        @packet += setstring(val)
      when Type::SIGNATURE
        @packet += setsignature(val)
      when ARRAY
        raise TypeException if val.class != Array
        array do
          val.each do |elem|
            append(type.child, elem)
          end
        end
      when STRUCT
        raise TypeException if val.class != Array
        struct do
          idx = 0
          while val[idx] != nil
            type.members.each do |subtype|
              raise TypeException if data[idx] == nil
              append_sig(subtype, data[idx])
              idx += 1
            end
          end
        end
      else
        raise NotImplementedException
      end
    end

  end

  class Message
    @@serial = 1
    @@serial_mutex = Mutex.new
    MESSAGE_SIGNATURE = "yyyyuua(yyv)"

    INVALID = 0
    METHOD_CALL = 1
    METHOD_RETURN = 2
    ERROR = 3
    SIGNAL = 4

    NO_REPLY_EXPECTED = 0x1
    NO_AUTO_START = 0x2

    attr_accessor :message_type
    attr_accessor :path, :interface, :member, :error_name, :destination,
      :sender, :signature, :reply_serial
    attr_reader :protocol, :serial, :params

    def initialize(mtype = INVALID)
      @message_type = mtype
      @flags = 0
      @protocol = 1
      @body_length = 0
      @signature = ""
      @@serial_mutex.synchronize do
        @serial = @@serial
        @@serial += 1
      end
      @params = Array.new
    end

    def add_param(type, val)
      @signature += type.chr
      @params << [type, val]
    end

    PATH = 1
    INTERFACE = 2
    MEMBER = 3
    ERROR_NAME = 4
    REPLY_SERIAL = 5
    DESTINATION = 6
    SENDER = 7
    SIGNATURE = 8

    def marshall
      params = PacketMarshaller.new
      @params.each do |param|
        params.append(param[0], param[1])
      end
      @body_length = params.packet.length

      marshaller = PacketMarshaller.new
      marshaller.append(Type::BYTE, HOST_END)
      marshaller.append(Type::BYTE, @message_type)
      marshaller.append(Type::BYTE, @flags)
      marshaller.append(Type::BYTE, @protocol)
      marshaller.append(Type::UINT32, @body_length)
      marshaller.append(Type::UINT32, @serial)
      marshaller.array do
        if @path
          marshaller.struct do
            marshaller.append(Type::BYTE, PATH)
            marshaller.append(Type::BYTE, 1)
            marshaller.append_string("o")
            marshaller.append(Type::OBJECT_PATH, @path)
          end
        end
        if @destination
          marshaller.struct do
            marshaller.append(Type::BYTE, DESTINATION)
            marshaller.append(Type::BYTE, 1)
            marshaller.append_string("s")
            marshaller.append(Type::STRING, @destination)
          end
        end
        if @interface
          marshaller.struct do
            marshaller.append(Type::BYTE, INTERFACE)
            marshaller.append(Type::BYTE, 1)
            marshaller.append_string("s")
            marshaller.append(Type::STRING, @interface)
          end
        end
        if @member
          marshaller.struct do
            marshaller.append(Type::BYTE, MEMBER)
            marshaller.append(Type::BYTE, 1)
            marshaller.append_string("s")
            marshaller.append(Type::STRING, @member)
          end
        end
        if @signature != ""
          marshaller.struct do
            marshaller.append(Type::BYTE, SIGNATURE)
            marshaller.append(Type::BYTE, 1)
            marshaller.append_string("g")
            marshaller.append(Type::SIGNATURE, @signature)
          end
        end
      end
      marshaller.align8
      @params.each do |param|
        marshaller.append(param[0], param[1])
      end
      marshaller.packet
    end

    def unmarshall_buffer(buf)
      buf = buf.dup
      if buf[0] == ?l
        endianness = LIL_END
      else
        endianness = BIG_END
      end
      pu = PacketUnmarshaller.new(buf, endianness)
      dummy, @message_type, @flags, @protocol, @body_length, @serial,
        headers = pu.unmarshall(MESSAGE_SIGNATURE)
      headers.each do |struct|
        case struct[0]
        when PATH
          @path = struct[2]
        when INTERFACE
          @interface = struct[2]
        when MEMBER
          @member = struct[2]
        when ERROR_NAME
          @error_name = struct[2]
        when REPLY_SERIAL
          @reply_serial = struct[2]
        when DESTINATION
          @destination = struct[2]
        when SENDER
          @sender = struct[2]
        when SIGNATURE
          @signature = struct[2]
        end
      end
      pu.align8
      if @body_length > 0 and @signature
        @params = pu.unmarshall(@signature, @body_length)
      end
      [self, pu.idx]
    end

    def unmarshall(buf)
      ret, size = unmarshall_buffer(buf)
      ret
    end
  end

  class IncompleteBufferException < Exception
  end

  class Connection
    attr_reader :unique_name
    def initialize(path)
      @path = path
      @unique_name = nil
      @buffer = ""
      @method_call_replies = Hash.new
      @method_call_msgs = Hash.new
    end

    # You need a patched libruby for this to connect
    def connect
      parse_session_string
      @socket = Socket.new(Socket::Constants::PF_UNIX,
                           Socket::Constants::SOCK_STREAM, 0)
      sockaddr = Socket.pack_sockaddr_un("\0" + @unix_abstract)
      @socket.connect(sockaddr)
      init_connection
      send_hello
    end

    def writel(s)
      @socket.write("#{s}\r\n")
    end

    def send(buf)
      @socket.write(buf)
    end

    def readl
      @socket.readline.chomp
    end

    NAME_FLAG_ALLOW_REPLACEMENT = 0x1
    NAME_FLAG_REPLACE_EXISTING = 0x2
    NAME_FLAG_DO_NOT_QUEUE = 0x4

    REQUEST_NAME_REPLY_PRIMARY_OWNER = 0x1
    REQUEST_NAME_REPLY_IN_QUEUE = 0x2
    REQUEST_NAME_REPLY_EXISTS = 0x3
    REQUEST_NAME_REPLY_ALREADY_OWNER = 0x4

    def request_name(name, flags)
      m = Message.new
      m.message_type = DBus::Message::METHOD_CALL
      m.path = "/org/freedesktop/DBus"
      m.destination = "org.freedesktop.DBus"
      m.interface = "org.freedesktop.DBus"
      m.member = "RequestName"
      m.add_param(Type::STRING, name)
      m.add_param(Type::UINT32, flags)
      s = m.marshall
      send(s)
      m.serial
    end

    # not working
    def ping
      m = Message.new
      m.message_type = DBus::Message::METHOD_CALL
      m.path = "/org/freedesktop/DBus"
      m.destination = "org.freedesktop.DBus"
      m.interface = "org.freedesktop.DBus.Peer"
      m.member = "Ping"
      s = m.marshall
      send(s)
    end

    def poll_message
      ret = nil
      size = nil
      r, d, d = IO.select([@socket], nil, nil, 0)
      if @buffer.size > 0 or (r and r.size > 0)
        if r and r.size > 0
          @buffer += @socket.read_nonblock(4096)
        end
        begin
          ret, size = Message.new.unmarshall_buffer(@buffer)
          @buffer.slice!(0, size)
        rescue IncompleteBufferException => e
          puts e.backtrace
          puts "Got IncompleteBufferException with #{@buffer.inspect}"
        end
      end
      ret
    end

    def wait_for_msg
      ret = poll_message
      while ret == nil
        r, d, d = IO.select([@socket])
        if r and r[0] == @socket
          ret = poll_message
        end
      end
      ret
    end

    def on_return(m, &retc)
      # for debug
      @method_call_msgs[m.serial] = m
      @method_call_replies[m.serial] = retc
    end

    def process(m)
      case m.message_type
      when DBus::Message::METHOD_RETURN
        raise InvalidPacketException if m.reply_serial == nil
        mcs = @method_call_replies[m.reply_serial]
        if not mcs
          puts "no return code for #{mcs.inspect} (#{m.inspect})"
        else
          mcs.call(m, *m.params)
          @method_call_replies.delete(m.reply_serial)
          @method_call_msgs.delete(m.reply_serial)
        end
      end
    end

    ############################################################################
    private

    def send_hello
      m = Message.new
      m.message_type = DBus::Message::METHOD_CALL
      m.path = "/org/freedesktop/DBus"
      m.destination = "org.freedesktop.DBus"
      m.interface = "org.freedesktop.DBus"
      m.member = "Hello"
      on_return(m) do |rmsg, weird_integer|
        @unique_name = rmsg.destination
        puts "Got hello reply. Our unique_name is #{@unique_name}"
      end
      send(m.marshall)
    end

    def parse_session_string
      @path.split(",").each do |eqstr|
        idx, val = eqstr.split("=")
        case idx
        when "unix:abstract"
          @unix_abstract = val
        when "guid"
          @guid = val
        end
      end
    end

    def init_connection
      @socket.write("\0")
      # TODO: code some real stuff here
      writel("AUTH EXTERNAL 31303030")
      s = readl
      # parse OK ?
      writel("BEGIN")
    end
  end
end # module DBus

