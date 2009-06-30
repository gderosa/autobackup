#!/usr/bin/env ruby

# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'pp' # DEBUG

require 'rubygems'
require 'net/ssh'
require 'net/sftp'
require 'uuid'
require 'highline/import'

require 'machine'
require 'disk'
require 'file'

class Autobackup

  Lshw_xml = "lshw.xml"
  Machine_dat = "machine.dat"
  Parted_txt = "parted.txt"
  Disks_dat = "disks.dat"
  Lshw_xml_cache = "/tmp/" + Lshw_xml
  Kernel_disk_by_id = "/dev/disk/by-id"
  SSH_keyfile = ENV["HOME"] + "/.ssh/id_rsa"
  SSH_keyfile_pub = SSH_keyfile + ".pub"

  def initialize
    @conf_file = 'autobackup.conf'
    @remote_machines = {}
    @machine_matches = []
    @remote_machine = nil                           # class Machine
    @current_disks = []
    @current_machine = nil                          # class Machine
    @current_machine_xmldata = ""                   # lshw -xml output
    @parted_output = ""                             # "@current_disks_textdata"
    @ssh_key = {
      :key => "",
      :local_already_present => false,
      :remote_already_present => false
    }
  end

  def run
    read_conf                                       # sets @conf
    parse_opts                                      # @conf['nocache']

    open_connection

    detect_hardware                                 # sets @current_machine

    detect_disks                                    # sets @current_disks 

    get_remote_machines  # retrieve Machine objects and fills @remote_machines

    find_machine_matches                             # fills @machine_matches

    ui

    close_connection

  end

  private

  def open_connection
    # Net::SSH connection is authenticated via password prompt, if no
    # keys available/accepted.
    #
    # Disk image uploads go through a separate connection 
    # (see Partition#backup), authenticated via keys which are created
    # on the fly, if necessary.
    #
    if File.readable? SSH_keyfile and File.readable? SSH_keyfile_pub
      @ssh_key[:local_already_present] = true
    else
      @ssh_key[:local_already_present] = false
      [SSH_keyfile, SSH_keyfile_pub].each do |f|
        File.remove f if File.exists? f
      end
      system("ssh-keygen -f #{SSH_keyfile} -P '' > /dev/null")
    end
    @ssh_key[:key] = File.read(SSH_keyfile_pub).strip # for later use...
    #print "Enter password to access the server: "
    #password = $stdin.gets.strip
    begin
      @ssh = Net::SSH.start(
        @conf['server'],
        @conf['user']
      )
      @ssh_key[:remote_already_present] = true
    rescue Net::SSH::AuthenticationFailed
      begin
        @ssh = Net::SSH.start(
          @conf['server'],
          @conf['user'],
          :password => ask("Enter password to access the server: ") \
            { |q| q.echo = "*" } 
        )
        @ssh_key[:remote_already_present] = false
      rescue Net::SSH::AuthenticationFailed
        puts "Wrong password. Exiting."
        exit
      end
    rescue
      STDERR.puts "ERROR: #{$!}"
      exit 2 
    end

    @sftp = Net::SFTP::Session.new(@ssh)
    @sftp.loop { @sftp.opening? } # wait until ready

    unless @ssh_key[:remote_already_present]
      # sftp does not support append mode...
      # TODO: what if remote home directory is not under /home ?
      # NOTE: "~/something" does not work!
      # TODO: query remote ENVironment?
      old = "/home/#{@conf['user']}/.ssh/authorized_keys"
      new = old + ".new"
      begin
        r = @sftp.file.open(old, 'r') 
        w = @sftp.file.open(new, 'w')
        w.puts @ssh_key[:key]
        while line = r.gets 
          w.puts line
        end
        @ssh.exec! "mv #{new} #{old}"
        r.close
        w.close
      rescue Net::SFTP::StatusException # remote authorized_keys doesn't exists
        w = @sftp.file.open(old, 'w') # which is, in fact, new ;-D
        w.puts @ssh_key[:key]
        w.close
      end
    end
  end

  def close_connection
    unless @ssh_key[:remote_already_present]
      # When finished, remove our temporary ssh key from remote list
      # to not clutter server's .ssh/authorized_keys
      #
      # TODO: what if remote home directory is not under /home ?
      # NOTE: tilde substitution (e.g. ~/some/thing) does not work!
      # TODO: query remote ENVironment?
      old = "/home/#{@conf['user']}/.ssh/authorized_keys"
      new = old + ".new"
      r = @sftp.file.open(old, 'r') 
      w = @sftp.file.open(new, 'w')
      while line = r.gets
        w.puts line unless line.strip == @ssh_key[:key].strip
      end
      @ssh.exec! "mv #{new} #{old}"
      r.close
      w.close
    end

    @sftp.close_channel
    @ssh.close
  end
  
  def read_conf
    @conf = {}
    File.foreach(@conf_file) do |line|
      line = line.strip!
      line = line.sub(/#.*$/,"")
      keyval = line.scan(/[^ =]+/)
      key, val = keyval
      val = false if ["false", "no"].include? val
      val = true if ["true", "yes"].include? val
      @conf[key] = val if key
    end
  end

  def parse_opts
    # Do Repeat Yourself ;-P
    ARGV.each do |arg|
      if arg == "--nocache"
        @conf['nocache'] = true 
      end
    end
  end

  def detect_hardware
    print "Detecting hardware... "
    $stdout.flush
    if @conf['nocache'] or (not File.readable?(Lshw_xml_cache))
      @current_machine_xmldata = `lshw -quiet -xml`
      f = File.open(Lshw_xml_cache, "w")
      f.print @current_machine_xmldata
      f.close
    else
      @current_machine_xmldata = File.read(Lshw_xml_cache)
    end
    @current_machine = Machine.new(
     :xmldata => @current_machine_xmldata,
     :id => UUID.new.generate )
    puts "done."
  end

  def detect_disks
    print "Finding disk(s) and partitions... "
    $stdout.flush
    disks_tmp_ary = []
    disk_tmp_hash = {:dev=>nil, :volumes=>[], :kernel_id=>nil, :size=>0}
    disk_tmp_dev = nil
    pipe = IO.popen("LANG=C && parted -m", "r+")
    pipe.puts "unit b"
    pipe.puts "print all"
    pipe.puts "quit"
    pipe.close_write
    lines = pipe.readlines
    @parted_output = ""
    lines.each do |line|
      line.gsub!(/\(parted\)/,"")
      line.gsub!(/\r/,"")
      @parted_output += line
      if line =~ /^(\/dev\/[^:]+):(.*):(.*):(.*):(.*):(.*):(.*);/ 
        if $3 == "dm"
          disk_tmp_dev = nil  # esclude device mapper
        else
          disk_tmp_dev = $1 # this block device is a whole disk, not a partition
          disk_tmp_hash = {
            :dev => disk_tmp_dev,
            :size => $2,
            :volumes => [],
            :kernel_id => nil
          }
          disks_tmp_ary << disk_tmp_hash
        end
      end
      if line =~ /^(\d+):(.*):(.*):(.*):(.+):(.*):(.*);/ and disk_tmp_dev
        pn  = $1
        dev = disk_tmp_dev + pn
        fstype = $5
        start = $2
        end_ = $3 # avoid conflict with a Ruby keyword ;-)
        size = $4
        disk_tmp_hash[:volumes] << {
          :kernel_id=>nil,
          :fstype=>fstype, 
          :dev=>dev, 
          :pn=>pn,
          :start=>start,
          :end=>end_,
          :size=>size
        }
      end
    end
    pipe.close_read
    dev_to_kernel_id = {}
    Dir.foreach(Kernel_disk_by_id) do |kernel_id|
      next if kernel_id =~ /^\./ # exclude '.' and '..' (and hidden entries) 
      dev = File.readlink!(Kernel_disk_by_id + '/' + kernel_id)
      dev_to_kernel_id[dev] = kernel_id
    end
    disks_tmp_ary.each do |d|
      d[:kernel_id] = dev_to_kernel_id[d[:dev]] 
      d[:volumes].each do |vol|
        vol[:kernel_id] =  dev_to_kernel_id[vol[:dev]]
      end
    end

    disks_tmp_ary.each {|d| @current_disks << Disk.new(d)}

    puts "done."
  end

  def create_remote_dir
    dir = @conf['dir'] + '/' + @current_machine.id
    @sftp.mkdir!(dir)
    @sftp.file.open(dir + "/" + Lshw_xml, "w") do |f|
      f.puts @current_machine_xmldata
    end      
    @sftp.file.open(dir + "/" + Machine_dat, "w") do |f|
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

  def find_machine_matches
    @machine_matches = []
    min_percent_match = 0.2 # first filter
    @remote_machines.each_value do |remote_machine|
      match = @current_machine.compare_to_w_score(remote_machine)
      if match[:percent_match] > min_percent_match
        match[:id] = remote_machine.id
        @machine_matches << match
      end
    end
    @machine_matches = @machine_matches.sort_by {|m| -m[:percent_match]}  
    return if @machine_matches.length == 0
    min_percent_match = @machine_matches[0][:percent_match]*0.6 # 2nd filter
    @machine_matches.reject! {|m| m[:percent_match]<min_percent_match} 
  end

  def ui
    puts ""
    case @machine_matches.length
    when 0
      puts "No matching machine found in the database: creating a new entry."
      print "Choose a name for this computer: "
      while `hostname #{$stdin.gets.strip} 2>&1`.length > 0 
        print "Invalid hostname. Choose another one: "
      end
      puts "Updating you data..."
      # re-run lshw to update hostname in the xml too...
      # TODO: more efficiently, edit @current_machine_xmldata in place
      @current_machine_xmldata = `lshw -quiet -xml`
      # rightly, do not parse the xml again, edit data structure directly
      @current_machine.data[:name] = `hostname`.strip
      @remote_machine = @current_machine
      create_remote_dir
      puts "\nOk. Your machine details follow:\n\n"
      puts @current_machine.ui_print
    when 1
      @remote_machine = @remote_machines[@machine_matches[0][:id]]
      puts "Machine has been identified as"
      print \
        "(#{(@machine_matches[0][:percent_match]*100).truncate/100}% match) | "
      puts @remote_machine.ui_print
    else  
      puts "I'm not sure of your machine identity. Choose one:"
      @machine_matches.each_index do |i|
        puts
        print "#{i + 1}. " +
          "(#{(@machine_matches[i][:percent_match]*100).truncate/100}% match)"+
          " | "
        puts @remote_machines[@machine_matches[i][:id]].ui_print
      end
      puts
      i = nil
      valid = false
      while not valid
        print "Enter the number and press ENTER: "
        str = $stdin.gets.strip
        begin
          i = str.to_i - 1
          @remote_machine = @remote_machines[@machine_matches[i][:id]]
          valid = true
          valid = false if not @remote_machine
          valid = false if i < 0 or i > @machine_matches.length-1
        rescue
          valid = false
        end
      end
      puts "\n You have chosen:"
      puts @remote_machine.ui_print
    end

    puts
    choice = ""
    while not %w{1 2 3}.include? choice
      puts "1. Backup"
      puts "2. Restore"
      puts "3. Exit"
      begin
        choice = $stdin.gets.strip
      rescue
        return 
      end
      case choice 
      when '1'
        ui_backup
      when '2' 
        puts "Not implemented yet"
        return
      when '3'
        return
      end
    end
  end

  def ui_backup
    # TODO? choose whether to backup all disks or just some of them
    machinedir = @conf['dir'] + "/" + @remote_machine.id

    @sftp.file.open(machinedir + "/" + Parted_txt, "w") do |f|
      f.puts @parted_output
    end
    @sftp.file.open(machinedir + "/" + Disks_dat, "w") do |f|
      f.puts Marshal::dump(@current_disks)
    end

    @current_disks.each do |disk| 
      diskdir = machinedir + "/" + disk.kernel_id

      begin
        @sftp.stat!(diskdir)
      rescue Net::SFTP::StatusException 
        @sftp.mkdir!(diskdir, :permissions=>0700) 
      end

      puts "\nBack up of #{disk.kernel_id} (#{disk.dev}, size=#{disk.size}):"
      disk.volumes.each do |part|
        volumedir = diskdir + "/" + part.pn

        begin
          @sftp.stat!(volumedir) 
        rescue Net::SFTP::StatusException 
          @sftp.mkdir!(volumedir, :permissions=>0700)
        end

        puts "\n  partition #{part.pn} (#{part.dev}):"
        part.backup(@conf, volumedir) 
        # part.backup(@sftp, volumedir) # the slower, pure-Ruby version
      end
    end
    puts
  end

end

Autobackup.new.run

