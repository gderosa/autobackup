#!/usr/bin/env ruby

# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009, 2010 Guido De Rosa <guido.derosa*vemarsas.it>
# License::   General Public License, version 2

require 'pp' # DEBUG

require 'fileutils'
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

  def ui
    puts ""
    case @machine_matches.length
    when 0
      name = ""
      print "This is the first time you backup this computer. "
      print "Choose a name for it:\n"
      while name=$stdin.gets.strip 
        break if name =~ /^[0-9a-z](.*\S)?$/i
        print "Invalid name. Choose another one: "
      end
      puts "Updating you data..."
      xmldoc = REXML::Document::new @current_machine_xmldata
      xmldoc.root.attributes["id"] = name
      @current_machine_xmldata = "<?xml version=\"1.0\" standalone=\"yes\" ?>\n"
      # the following method will append, not rewrite (calls '<<' ) 
      REXML::Formatters::Default.new.write(xmldoc.root, @current_machine_xmldata)
      # rightly, do not parse the xml again, edit data structure directly
      @current_machine.data[:name] = name
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

    if $single_command == 'clone'
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
          passphrase = ui_create_passphrase
          ui_backup(:passphrase => passphrase) 
        when '2' 
          passphrase = ui_get_passphrase
          choice = :__invalid__ unless ui_restore(passphrase)
        when '3'
          return
        end
      end
    elsif $single_command == 'archive'
      passphrase = ui_create_passphrase
      ui_backup(:passphrase => passphrase)
    end
  end

  def ui_get_passphrase
    passphrase = ask(
        "Enter the passphrase if data are encrypted (leave empty otherwise)"
    ) {|q| q.echo = '*'}
    if passphrase =~ /\S/
      return passphrase
    else
      return nil
    end
  end

  def ui_create_passphrase
    loop do
      passphrase = 
          ask("Passphrase (or leave empty to no encrypt data): ") do |q| 
        q.echo = '*'
      end
      return nil if passphrase == ""
      passphrase2 = ask("Passphrase (verify): ") {|q| q.echo = '*'}
      if passphrase == passphrase2
        return passphrase.strip
      else
        say "Passphrase mismatch!" 
      end
    end
  end

  def ui_backup(h)
    machine_id = @current_machine.id = @remote_machine.id
    @current_machine.data[:name] = @remote_machine.data[:name]
    save_current_machine # overwrite old hardware data

    machinedir = File.expand_path ( @conf['localdir'] + "/" + machine_id )

    File.open(machinedir + "/" + Parted_txt, "w") do |f|
      f.puts @parted_output
    end
    File.open(machinedir + "/" + Disks_dat, "w") do |f|
      f.puts Marshal::dump(@current_disks)
    end
    File.open(machinedir + "/name", "w") do |f|
      f.puts @current_machine.data[:name]
    end
    # Don't trust id attribute in XML to get machine saved name in a human
    # readable form, you will read "name" file instead

    FileUtils::ln_sf( 
        machinedir, 
        "#{ROOTDIR}/names/#{@current_machine.data[:name]}"
    )

    @current_disks.each do |disk| 
      next if (not disk.kernel_id) or disk.kernel_id.length < 1
        # to avoid cdroms etc.

      puts "\nBack up of #{disk.kernel_id}" + \
        "\n (#{disk.dev}, size=#{disk.size})" # TODO: Disk#ui_print?

      if $single_command == 'archive'
        archive_format = :"7z"

        choose do |menu|
          menu.prompt = "Archive format?"
          menu.choice(:"7z") { archive_format = :"7z" }
          menu.choices(:"tar.gz") { archive_format = :"tar.gz" }
          menu.choices(:dar) { archive_format = :dar }
        end
      end
      
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
          part.backup(
            :volumedir => volumedir, 
            :passphrase => h[:passphrase],
            :archive_format => archive_format
          ) 
          part.mount(mountpoint_save) if mountpoint_save
        end
      end
    end
    puts
  end

  def ui_restore(passphrase=nil)
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

        result = disk.restore(
            @remote_disks, 
            @remote_machine, 
            @conf['localdir'],
            {:passphrase => passphrase}
        )
        if result[:state] == :not_found_the_same_disk
          puts "Which of these disks you want to restore from?"
          @remote_disks.each_index do |i|
            rdisk = @remote_disks[i]
            puts "#{i+1}. #{rdisk.model} #{rdisk.size} \n (#{rdisk.kernel_id})"
          end
          puts (@remote_disks.length + 1).to_s + ". None."
          i = ask("?", Integer) { |q| q.in = 1..(@remote_disks.length + 1) } - 1
          result = disk.restore(
              @remote_disks[i], 
              @remote_machine, 
              @conf['localdir'],
              {:passphrase => passphrase}
          )
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
                {:passphrase => passphrase},
                :dont_check_ptable
            ) 
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

end


