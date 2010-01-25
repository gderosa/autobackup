#!/usr/bin/env ruby

# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'pp' # DEBUG

#require 'fileutils'
require 'rubygems'
require 'uuid'
require 'highline/import'
require 'rexml/document'

require 'machine'
require 'disk'
require 'partition'
require 'netvolume'
require 'file'
require 'ui'

ROOTDIR = File.dirname(File.expand_path __FILE__)

class Autobackup

  Lshw_xml = "lshw.xml"
  Machine_dat = "machine.dat"
  Parted_txt = "parted.txt"
  Disks_dat = "disks.dat"
  Lshw_xml_cache = "/tmp/" + Lshw_xml
  Kernel_disk_by_id = "/dev/disk/by-id"
  Single_Commands = %w{clone archive antivirus}

  def initialize
    @conf_file = 'autobackup.conf'
    @remote_machines = {}
    @machine_matches = []
    @remote_machine = nil                           # class Machine
    @current_disks = []
    @remote_disks = []            # volume images available
    @current_machine = nil                          # class Machine
    @current_machine_xmldata = ""                   # lshw -xml output
    @parted_output = ""                             # "@current_disks_textdata"
    @network_fs = nil
    @network_previously_mounted = false
  end

  def run
    read_conf                                       # sets @conf
    parse_opts                                      # overwrite @conf as needed
    mount_network                                   # ..or use local dir 
    validate_conf                                   # check @conf is valid
    detect_hardware                                 # sets @current_machine
    detect_disks                                    # sets @current_disks 
    get_remote_machines  # retrieve Machine objects and fills @remote_machines
    find_machine_matches                            # fills @machine_matches
    ui
    @network_fs.umount if @network_fs and not @network_previously_mounted
  end

  private

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

    waiting = nil
    $single_command = nil
    
    ARGV.each do |arg|

      if Single_Commands.include? arg
        if $single_command
          fail "ERR: You must specify a single operation among the following ones: #{Single_Commands.join(' ')}"
        else
          $single_command = arg
        end
      end

      if (waiting) # option catched in the previous cycle now gets its argument
        @conf[waiting] = arg
        waiting = nil
      end
      
      # options without arguments
      %w{nocache noninteractive}.each do |opt| 
        if arg == "--" + opt
          @conf[opt] = true
          next 
        end
      end

      # options which will receive an argument
      %w{dir localdir}.each do |opt| 
        if arg == "--" + opt
          waiting = opt
          next
        end
      end

    end

  end

  def validate_conf
    unless @conf['localdir']
      STDERR.puts "@conf['localdir'] not set... ARGHH!!"
      exit 1
    end
  end

  def mount_network
    return unless @conf['dir']
    if @conf['dir'] =~ /^ssh:\/\/([^@]+@[^:]+:\S+)/
      @network_fs = NetVolume.new( 
        :dev => $1,
        :fstype => "fuse.sshfs"
      )
      if @network_fs.mounted?
        @network_previously_mounted = true 
        @conf['localdir'] = @network_fs.mountpoint
      else
      	puts "Contacting server..."
        if @conf['localdir']
          @network_fs.mount(@conf['localdir']) 
        else
          @network_fs.mount
          @conf['localdir'] = @network_fs.mountpoint
        end
      end
    else
      @conf['localdir'] = @conf['dir']
    end
  end

  def detect_hardware
    puts "Detecting hardware... "
    #$stdout.flush
    if @conf['nocache'] or (not File.readable?(Lshw_xml_cache))
      @current_machine_xmldata = `sudo lshw -xml`
      f = File.open(Lshw_xml_cache, "w")
      f.print @current_machine_xmldata
      f.close
    else
      @current_machine_xmldata = File.read(Lshw_xml_cache)
    end
    @current_machine = Machine.new(
     :xmldata => @current_machine_xmldata,
     :id => UUID.new.generate )
    #puts "done."
  end

  def detect_disks
    @current_disks = []
    print "Finding disk(s) and partitions... "
    $stdout.flush
    disks_tmp_ary = []
    disk_tmp_hash = {:dev=>nil, :volumes=>[], :kernel_id=>nil, :size=>0}
    disk_tmp_dev = nil
    # NOTE: WARNING: older versions of GNU parted do not support -m option!
    # Upgrade to a newer one if necessary.
    pipe = IO.popen("LANG=C && parted -lm", "r")
    #pipe.puts "unit b" # let's try to keep it human readable!
      # another advantage is "fuzzy" comparison between partition sizes
    #pipe.puts "print all"
    #pipe.puts "quit"
    #pipe.close_write
    lines = pipe.readlines
    @parted_output = ""
    lines.each do |line|
      line.gsub!(/\(parted\)/,"")
      line.gsub!(/\r/,"")
      @parted_output += line
      # totally compromised mbr/part.table
      if line =~ /err.*(\/dev\/[a-z]+)[:\s]/i or
        line =~ /(\/dev\/[a-z]+)[:\s].*unrecognized disk label/i

        disk_tmp_dev = $1
        disk_tmp_hash = {
          :dev => disk_tmp_dev,
          :size => 0,
          :volumes => [],
          :kernel_id => nil,
          :model => nil
        }
        disks_tmp_ary << disk_tmp_hash
      # disk found:
      elsif line =~ /^(\/dev\/[^:]+):(.*):(.*):(.*):(.*):(.*):(.*);/ 
        if $3 == "dm"
          disk_tmp_dev = nil  # esclude device mapper
        else
          disk_tmp_dev = $1 # this block device is a whole disk, not a partition
          disk_tmp_hash = {
            :dev => disk_tmp_dev,
            :size => $2,
            :volumes => [],
            :kernel_id => nil,
            :model => $7
          }
          disks_tmp_ary << disk_tmp_hash
        end
      end
      # partition:
      if line =~ /^(\d+):(.*):(.*):(.*):(.*):(.*):(.*);/ and disk_tmp_dev
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
    begin
      Dir.foreach(Kernel_disk_by_id) do |kernel_id|
        next if kernel_id =~ /^\./ # exclude '.' and '..' (and hidden entries) 
        dev = File.readlink!(Kernel_disk_by_id + '/' + kernel_id)
        dev_to_kernel_id[dev] = kernel_id
      end
    rescue
      STDERR.puts "Warning: no disks! (no /dev/disk/by-id found)"
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

  def save_current_machine
    dir = @conf['localdir'] + '/' + @current_machine.id
    Dir.mkdir(dir, 0700) unless File.directory?(dir)
    File.open(dir + "/" + Lshw_xml, "w") do |f|
      f.puts @current_machine_xmldata
    end      
    File.open(dir + "/" + Machine_dat, "w") do |f|
      f.puts Marshal::dump(@current_machine.data)
    end
  end

  def get_remote_machines
    print "Retrieving machines remote data."
    $stdout.flush
    basedir = @conf['localdir']
    unless File.directory?(basedir)
      STDERR.puts ".. Ooops!\n--> directory #{basedir} does not exists!\nExiting."
      exit 1
    end
    Dir.entries(basedir).each do |entry|
      next unless File.directory? File.join(basedir, entry)
      name = entry
      unless name =~ /^\./  #exclude '.' ,  '..' and hidden files/directories
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
    min_percent_match = 60 # first filter
    @remote_machines.each_value do |remote_machine|
      match = @current_machine.compare_to_w_score(remote_machine)
      next unless match # skip ``nil''
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

  def get_remote_disks
    machinedir = @conf['localdir'] + "/" + @remote_machine.id
    disks_datfile = machinedir + "/" + Disks_dat
    if File.exists?(disks_datfile)
      @remote_disks = Marshal::load(File.read(disks_datfile)) 
    end
  end

end

Autobackup.new.run

