# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'pp' # DEBUG

require 'rubygems'
require 'net/ssh'
require 'net/sftp'
require 'uuid'

require 'machine'

class Autobackup

	def initialize
		@conf_file = 'autobackup.conf'
		@remote_machines = []
	end

  def run
    read_conf																				# sets @conf

		#@current_machine_xmldata = `lshw -xml`
		#@current_machine = Machine::new(
		#	:xmldata => @current_machine_xmldata,
		# :id => UUID::new.generate )

		open_connection																	# sets @ssh, @sftp

		get_remote_machines	# retrieve Machine objects and fill @remote_machines
		
		# create_remote_dir

		# gets # DEBUG
		
		close_connection

		pp @remote_machines # DEBUG

  end

  private

	def open_connection
		@ssh = Net::SSH.start(
	    @conf['server'],
	    @conf['user'],
	    :password => @conf['passwd']
		)
		@sftp = Net::SFTP::Session.new(@ssh)
		@sftp.loop { @sftp.opening? } # wait until ready
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
		  unless name =~ /^\.\.?$/     								#exclude '.' and '..'
				@remote_machines.push(
					Machine.new(
						:id => name, 
						:remote => {
							:sftp => @sftp,
							:basedir => basedir
						}
					)
				)
				puts "Retrieved: #{name}" # DEBUG | PROGRESS | VERBOSE
			end
		end
	end

end

Autobackup::new.run

