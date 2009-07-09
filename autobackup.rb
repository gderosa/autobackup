#!/usr/bin/env ruby

# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'pp' # DEBUG

require 'rubygems'
require 'uuid'
require 'highline/import'
require 'rexml/document'

require 'machine'
require 'disk'
require 'partition'
require 'netvolume'
require 'file'

class Autobackup

  Lshw_xml = "lshw.xml"
  Machine_dat = "machine.dat"
  Parted_txt = "parted.txt"
  Disks_dat = "disks.dat"
  Lshw_xml_cache = "/tmp/" + Lshw_xml
  Kernel_disk_by_id = "/dev/disk/by-id"

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
    mount_network
    validate_conf                                   # check @conf is valid
    detect_hardware                                 # sets @current_machine
    detect_disks                                    # sets @current_disks 
    get_remote_machines  # retrieve Machine objects and fills @remote_machines
    find_machine_matches                             # fills @machine_matches
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

    aliases = {}

    waiting = nil
    
    ARGV.each do |arg|

      aliases.each_pair {|old, new| arg = new if arg == old} 

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
      @current_machine_xmldata = `lshw -xml`
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
    pipe = IO.popen("LANG=C && parted -m", "r+")
    #pipe.puts "unit b" # let's try to keep it human readable!
      # another advantage is "fuzzy" comparison between partition sizes
    pipe.puts "print all"
    pipe.puts "quit"
    pipe.close_write
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
      name = entry
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
    min_percent_match = 20 # first filter
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
      name = ""
      print "This is the first time you backup this computer. "
      print "Choose a name for it:\n"
      while `hostname #{name=$stdin.gets.strip} 2>&1`.length > 0 
        print "Invalid hostname. Choose another one: "
      end
      puts "Updating you data..."
      xmldoc = REXML::Document::new @current_machine_xmldata
      puts name
      puts xmldoc.root.attributes["id"]
      xmldoc.root.attributes["id"] = name
      puts xmldoc.root.attributes["id"]
      @current_machine_xmldata = "<?xml version=\"1.0\" standalone=\"yes\" ?>\n"
      # the following method will append, not rewrite (calls '<<' ) 
      REXML::Formatters::Default.new.write(xmldoc.root, @current_machine_xmldata)
      # rightly, do not parse the xml again, edit data structure directly
      @current_machine.data[:name] = `hostname`.strip
      @remote_machine = @current_machine
      save_current_machine
      puts "\nOk. Your machine details follow:\n\n"
      puts @current_machine.ui_print

      @remote_disks = []
    when 1
      @remote_machine = @remote_machines[@machine_matches[0][:id]]
      puts "Machine has been identified as"
      print \
        "(#{@machine_matches[0][:percent_match].round}% match) | "
      puts @remote_machine.ui_print

      get_remote_disks # fills @remote_disks
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

      get_remote_disks # fills @remote_disks, once @remote_machine is set
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
        choice = :__invalid__ unless ui_restore    
      when '3'
        return
      end
    end
  end

  def ui_backup
    machine_id = @current_machine.id = @remote_machine.id
    save_current_machine # overwrite old hardware data

    machinedir = @conf['localdir'] + "/" + machine_id

    File.open(machinedir + "/" + Parted_txt, "w") do |f|
      f.puts @parted_output
    end
    File.open(machinedir + "/" + Disks_dat, "w") do |f|
      f.puts Marshal::dump(@current_disks)
    end

    @current_disks.each do |disk| 
      next if (not disk.kernel_id) or disk.kernel_id.length < 1
        # to avoid cdroms etc.

      puts "\nBack up of #{disk.kernel_id}" + \
        "\n (#{disk.dev}, size=#{disk.size})" # TODO: Disk#ui_print?
      
      if @conf['noninteractive'] or (agree("Proceed?") {|q| q.default="yes"})

        diskdir = machinedir + "/" + disk.kernel_id

        begin
          File.stat(diskdir)
        rescue Errno::ENOENT
          Dir.mkdir(diskdir, 0700)   
        end

        disk.backup_mbr(diskdir)
        disk.backup_ptable(diskdir)

        disk.volumes.each do |part|
          next if ["linux-swap", ""].include? part.fstype

          # if mounted, try to unmount, backup and remount

          if ( mountpoint_save = part.mountpoint )
            if !part.umount # couldn't unmount -> skip
              puts "\nCould not unmont partition" + 
                " #{part.pn} (#{part.dev}) Type = #{part.fstype}"
              puts "--> Skipped"
              next
            end
          end
          
          volumedir = diskdir + "/" + part.pn

          unless File.exists?(volumedir) 
            Dir.mkdir(volumedir, 0700)
          end

          puts "\n  partition #{part.pn} (#{part.dev}) Type = #{part.fstype}"
          part.backup(volumedir) 
          part.mount(mountpoint_save) if mountpoint_save
        end
      end
    end
    puts
  end

  def ui_restore
    if @remote_disks.length == 0
      print "\nUnavailable: no backup of this machine has been made!\n\n"
      return false
    end

    @current_disks.clone.each_with_index do |disk, disk_index| 

      next if (not disk.kernel_id) or disk.kernel_id.length < 1
        # to avoid cdroms etc.
      puts "\nRestore of #{disk.kernel_id}" + \
        "\n (#{disk.dev}, size=#{disk.size})" 
      if @conf['noninteractive'] or (agree("Proceed?") {|q| q.default="no"})

        result = disk.restore(@remote_disks, @remote_machine, @conf['localdir'])
        if result[:state] == :not_found_the_same_disk
          puts "Which of these disks you want to restore from?"
          @remote_disks.each_index do |i|
            rdisk = @remote_disks[i]
            puts "#{i+1}. #{rdisk.model} #{rdisk.size} \n (#{rdisk.kernel_id})"
          end
          puts (@remote_disks.length + 1).to_s + ". None."
          i = ask("?", Integer) { |q| q.in = 1..(@remote_disks.length + 1) } - 1
          result = disk.restore(
            @remote_disks[i], @remote_machine, @conf['localdir'])
        end

        # Restore partition table and/or MBR. 
        #
        # TODO: support GUID partition tables?
        #
        # Apparently, the right order to do things is:
        #   sfdisk < sfdisk-d.txt
        #   dd if=mbr.bin of=/dev/hda 
        # as opposite to what reads here:
        # http://www.partimage.org/Partimage-manual_Backup-partition-table#Restoring_partition_entries_from_the_backup
        if result[:state] == :no_ptable
          restore_ptable = \
            agree("Partition tables do not match. Restore it [y/n]?")
          if restore_ptable
            restore_boot = agree("Restore the Boot Sector too?") do |q|
              q.default = "no"
            end
          end
          if restore_ptable
            disk.restore_ptable( # TODO: a more coherent API?
              @conf['localdir'] + "/" + 
              @remote_machine.id + "/" + 
              result[:disk].kernel_id) 
            detect_disks                      # re-run...
            disk = @current_disks[disk_index] # ...and update
            disk.restore(
              result[:disk], 
              @remote_machine, 
              @conf['localdir'],
              :dont_check_ptable) 
          end
          if restore_boot
            disk.restore_mbr( 
              @conf['localdir'] + "/" + 
              @remote_machine.id + "/" + 
              result[:disk].kernel_id) 
          end
        end

      end

    end

    return true 
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

