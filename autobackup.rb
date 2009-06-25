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

class Autobackup

	def initialize
		@conf_file = 'autobackup.conf'
		@remote_machines = {}
    @matches = {}
    @matches_good = {}
    @current_partitions = []
	end

  def run

    read_conf																				# sets @conf
    parse_opts                                      # @conf['nocache']

    detect_hardware                                 # sets @current_machine

    set_current_partitions                          # sets @current_partitions 

    pp @current_partitions

		open_connection																	# sets @ssh, @sftp

		get_remote_machines	# retrieve Machine objects and fills @remote_machines

    find_matches                                    # fills @matches

		# create_remote_dir

		close_connection

  end

  private

	def open_connection
    puts "Contacting the server..."
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
    puts "Detecting hardware... "
		@current_machine_xmldata = `lshw -xml`
		@current_machine = Machine::new(
	   :xmldata => @current_machine_xmldata,
		 :id => UUID::new.generate )
  end

  def set_current_partitions
    # :logicalname has nothing to do with primary vs logical;
    # it may be "/dev/sda1" or "/dev/sda7" etc. 
    @current_machine.data[:disks].each do |disk|
      disk[:volumes].each do |volume|
        if volume[:logical_volumes] and volume[:logical_volumes].length > 0
          volume[:logical_volumes].each do |lvolume|
            @current_partitions << Partition.new(lvolume[:logicalname])
          end
        else
          @current_partitions << Partition.new(volume[:logicalname])
        end
      end
    end
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
				puts "Retrieved: #{name}" # DEBUG | PROGRESS | VERBOSE
			end
		end
	end

  def find_matches
    @remote_machines.each_value do |remote_machine|
      @matches[remote_machine.id] = \
        @current_machine.compare_to_w_score(remote_machine)
      if @matches[remote_machine.id][:percent_match] > 0.1
        @matches_good[remote_machine.id] = @matches[remote_machine.id]
      end
    end
  end

end

Autobackup::new.run

