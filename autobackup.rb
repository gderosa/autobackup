#!/usr/bin/env ruby

# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'pp' # DEBUG

require 'rubygems'
require 'net/ssh'
require 'net/sftp'
require 'uuid'

require 'machine'
require 'partition'
require 'file'

class Autobackup

	def initialize
		@conf_file = 'autobackup.conf'
		@remote_machines = {}
    @matches = {}
    @current_partitions = []
	end

  def run

    read_conf																				# sets @conf
    parse_opts                                      # @conf['nocache']

    detect_hardware                                 # sets @current_machine

    set_current_partitions                          # sets @current_partitions 

		open_connection																	# sets @ssh, @sftp

		get_remote_machines	# retrieve Machine objects and fills @remote_machines

    find_matches                                    # fills @matches

		# create_remote_dir

		close_connection

    pp @current_partitions

  end

  private

	def open_connection
    print "Contacting the server... "
    $stdout.flush
    begin
      @ssh = Net::SSH.start(
        @conf['server'],
        @conf['user'],
        :password => @conf['passwd']
      )
      @sftp = Net::SFTP::Session.new(@ssh)
      @sftp.loop { @sftp.opening? } # wait until ready
    rescue
      STDERR.puts "ERROR: #{$!}"
      exit 2 
    end
    puts "done."
	end

	def close_connection
		@sftp.close_channel
		@ssh.close
	end
  
  def read_conf
    @conf = {}
    File.foreach(@conf_file) do |line|
      line = line.strip!
      line = line.sub(/#.*$/,"")
      keyval = line.scan(/[^ =]+/)
      @conf[keyval[0]] = keyval[1] if (keyval[0])
    end
  end

  def parse_opts
    # Do Repeat Yourself ;-P
    ARGV.each do |arg|
      if arg == "--nocache"
        @conf['nocache'] = 'true' # @conf is made up of strings
      end
    end
  end

  def detect_hardware
    print "Detecting hardware... "
    $stdout.flush
		@current_machine_xmldata = `lshw -quiet -xml`
    puts "done."
		@current_machine = Machine::new(
	   :xmldata => @current_machine_xmldata,
		 :id => UUID::new.generate )
  end

  def set_current_partitions
    print "Finding disk(s) partitions... "
    $stdout.flush
    disk = nil
    IO.popen("parted -lms").each_line do |line|
      if line =~ /^(\/dev\/[^:]+):(.*):(.*):(.*):(.*):(.*):(.*);/ 
        if $3 == "dm"
          disk = nil  # esclude device mapper
        else
          disk = $1
        end
      end
      if line =~ /^(\d+):(.*):(.*):(.*):(.+):(.*):(.*);/ and disk
        dev = disk + $1
        fstype = $5
        @current_partitions << {:fstype=>fstype, :dev=>dev}   
      end
    end
    kernel_disk_id_basedir = '/dev/disk/by-id'
    Dir.foreach(kernel_disk_id_basedir) do |item|
      next if item =~ /^\./ # exclude '.' and '..' (and hidden entries) 
      dev = File.readlink!(kernel_disk_id_basedir + '/' + item)
      if p = @current_partitions.detect {|x| x[:dev] == dev} 
        p[:kernel_id] = item
      end
    end
    puts "done."
  end

  def create_remote_dir
    dir = @conf['dir'] + '/' + @current_machine.id
		@sftp.mkdir!(dir)
    @sftp.file.open(dir + "/lshw.xml", "w") do |f|
      f.puts @current_machine_xmldata
    end	    
		@sftp.file.open(dir + "/machine.dat", "w") do |f|
			f.puts Marshal::dump(@current_machine.data)
		end
  end

	def get_remote_machines
    print "Retrieving machines remote data."
    $stdout.flush
		basedir = @conf['dir']
		@sftp.dir.foreach(basedir) do |entry|
			name = entry.name
		  unless name =~ /^\./  #exclude '.' and '..' and hidden directories
				@remote_machines[name] = \
					Machine.new(
						:id => name, 
						:remote => {
							:sftp => @sftp,
							:basedir => basedir,
              :nocache => @conf['nocache']
						}
					)
				print "."
        $stdout.flush
			end
		end
    puts " done."
	end

  def find_matches
    min_percent_match = 0.2
    @remote_machines.each_value do |remote_machine|
      match = @current_machine.compare_to_w_score(remote_machine)
      if match[:percent_match] > min_percent_match
        @matches[remote_machine.id] = match
      end
    end
  end

end

Autobackup::new.run

