require 'json'
require 'zmq'
require './hash'
require './vclock'
require './threads'
require './reply-service'
require './coordinator'


# an object to store in a server node
class NodeObject
  attr_accessor :value, :vclock
  def initialize(value, vclock)
    @value = value
    @vclock = vclock
  end

  def <=>(nobject2)
    vclock <=> nobject2.vclock
  end

  def to_s
    {:value=>value, :vclock=>vclock}.to_json
  end

  def self.deserialize(serialized)
    data = JSON.parse(serialized)
    if Array === data
      data.map{|json|
        vclock = VectorClock.deserialize(json['vclock'])
        NodeObject.new(json['value'], vclock)
      }
    else
      vclock = VectorClock.deserialize(data['vclock'])
      NodeObject.new(data['value'], vclock)
    end
  end
end


# Manages a hash ring as well as a hash of data
class Node
  include Threads
  include ReplyService
  include Coordinator

  def initialize(name, nodes=[], partitions=32)
    @name = name
    @ring = PartitionedConsistentHash.new(nodes+[name], partitions)
    @data = {}
  end

  def config(name)
    (@configs ||= {})[name] ||= JSON::load(File.read("#{name}.json"))
  end

  def start(leader)
    coordination_services( leader )
    service( config(@name)["port"] )
    puts "#{@name} started"
    join_threads()
  end

  def put_counter(socket, payload)
    n, key, value = payload.split(' ', 3)
    socket.send( do_put(key, "{}", value, n.to_i, :counter).to_s )
  end

  def get_counter(socket, payload)
    n, key = payload.split(' ', 2)
    node_objects = do_get(key, n.to_i, :counter)
    # roll up any siblings
    value = node_objects.reduce(0) do |sum,v|
      sum + v.value.to_i
    end
    socket.send( value.to_s )
  end

  def put(socket, payload)
    n, key, vc, value = payload.split(' ', 4)
    socket.send( do_put(key, vc, value, n.to_i).to_s )
  end

  def get(socket, payload)
    n, key = payload.split(' ', 2)
    socket.send( do_get(key, n.to_i).to_s )
  end

  def do_put(key, vc, value, n=1, crdt=nil)
    if @ring.pref_list(key, n).include?(@name) || n == 0
      vclock = VectorClock.deserialize(vc)
      node_objects = []
      if current_objs = @data[@ring.hash(key)]
        if vclock.empty? && current_objs.length == 1
          # if no clock was given, use the old one
          vclock = current_objs.first.vclock
        elsif !vclock.empty? && !current_objs.find{|o| o.vclock.descends_from?(vclock)}
          # not a decendant of anything, ie conflict. add as a sibling
          node_objects += current_objs
        end
      end
      vclock.increment(@name) if n == 0
      node_objects = (current_objs || node_objects) if crdt
      if crdt == :counter && !node_objects.last.nil?
        node_objects.last.value = node_objects.last.value.to_i + value.to_i
      else
        node_objects += [NodeObject.new(value, vclock)]
      end
      puts "put #{n} #{key} #{vclock} #{value}"
      @data[@ring.hash(key)] = node_objects
      replicate("put 0 #{key} #{vclock} #{value}", key, n) unless n == 0
      node_objects
    else
      remote_call(@ring.node(key), "put #{n} #{key} #{vc} #{value}")
    end
  end

  def do_get(key, n=1, crdt=nil)
    if n == 0
      puts "get 0 #{key}"
      @data[@ring.hash(key)] || 'null'
    elsif @ring.pref_list(key, n).include?(@name)
      puts "get #{n} #{key}"
      results = []
      if n != 0
        results = replicate("get 0 #{key}", key, n)
        results.map! do |r|
          r == 'null' ? nil : NodeObject.deserialize(r)
        end
      end
      results << @data[@ring.hash(key)]
      results.flatten!
      results.uniq! {|o| o && o.value }
      results.compact!
      repair(key, n)
      begin
        # we get the most recent value if we can resolve this
        [results.sort.first]
      rescue
        # a conflic forces sublings
        puts "Conflict!"
        return results
      end
    else
      remote_call(@ring.node(key), "get #{n} #{key}")
    end
  end

  def replicate(message, key, n)
    list = @ring.pref_list(key, n) - [@name]
    results = []
    while replicate_node = list.shift
      results << remote_call(replicate_node, message)
    end
    results
  end

  def repair(key, n)
    list = @ring.pref_list(key, n) - [@name]
    puts "Repairing #{key}"
    list.map do |replicate_node|
      Thread.new do
        result = remote_call(replicate_node, "get 0 #{key}")
        remote_objs = NodeObject.deserialize(result)
        if remote_objs != 'null'
          # if local is nil or descends, update local
          local = @data[@ring.hash(key)]
          vclock = local && local.first.vclock
          descends = remote_objs.find{|o| o.vclock.descends_from?(vclock)}
          if vclock == nil || descends
            @data[@ring.hash(key)] = nos
          end
        end
      end
    end
  end

  def remote_call(remote_name, message)
    puts "#{remote_name} <= #{message}"
    remote_port = config(remote_name)["port"]
    ctx = ZMQ::Context.new
    req = ctx.socket(ZMQ::REQ)
    req.connect("tcp://127.0.0.1:#{remote_port}")
    resp = req.send(message) && req.recv
    req.close
    resp
  end

  def close
    inform_coordinator( 'down', config(@name)["coord_req"] )
  ensure
    exit!
  end
end



begin
  name, leader = ARGV
  leader = !leader.nil?
  $node = Node.new(name)
  trap("SIGINT") { $node.close }
  $node.start(leader)
end