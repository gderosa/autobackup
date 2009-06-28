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
require 'disk'
require 'file'

class Autobackup

  Lshw_xml = "lshw.xml"
  Machine_dat = "machine.dat"
  Lshw_xml_cache = "/tmp/" + Lshw_xml
  Kernel_disk_by_id = "/dev/disk/by-id"

  def initialize
    @conf_file = 'autobackup.conf'
    @remote_machines = {}
    @machine_matches = []
    @current_disks = []
  end

  def run

    read_conf                                       # sets @conf
    parse_opts                                      # @conf['nocache']

    detect_hardware                                 # sets @current_machine

    detect_disks                                    # sets @current_disks 

    open_connection                                 # sets @ssh, @sftp

    get_remote_machines  # retrieve Machine objects and fills @remote_machines

    find_machine_matches                             # fills @machine_matches

    # create_remote_dir

    ui

    close_connection

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
    pipe = IO.popen("parted -m", "r+")
    pipe.puts "unit b"
    pipe.puts "print all"
    pipe.puts "quit"
    pipe.close_write
    lines = pipe.readlines
    lines.each do |line|
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
    min_percent_match = @machine_matches[0][:percent_match]*0.5 # 2nd filter
    @machine_matches.reject! {|m| m[:percent_match]<min_percent_match} 
  end

  def ui
    puts ""
    case @machine_matches.length
    when 0
      puts "No matching machine found in the database: creating a new one."
      puts "Choose a name for the machine"
      while `hostname #{$stdin.gets.strip} 2>&1`.length > 0 
        puts "Invalid hostname. Choose another one"
      end
    when 1
      puts "Machine has been identified as"
      pp @remote_machines[@machine_matches[0][:id]] # TODO: Machine#pp
    # else (TODO) 
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
        exit
      end
      case choice 
      when '1'
        ui_backup
      when '2' 
        puts "Not implemented yet"
        exit
      when '3'
        exit
      end
    end
  end

  def ui_backup
  end

end

Autobackup.new.run

