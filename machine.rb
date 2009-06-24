# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'uuid'
require 'net/sftp'
require 'rexml/document'

require 'array'

class Machine

  attr_reader :data, :id

  def initialize(args)
    @id = ( args[:id] or UUID::new.generate )

    if args[:remote]

      sftp = args[:remote][:sftp]
      dir = args[:remote][:basedir] + '/' + args[:id] 
      xmlfile = dir + '/' + "lshw.xml"
      datfile = dir + '/' + "machine.dat"

      # A caching mechanism to not parse XML every time...
      begin # Update cache (i.e. datfile) if it's out of date
        if sftp.stat!(xmlfile).mtime > sftp.stat!(datfile).mtime
          @data = Machine::parse_lshw_xml(sftp.download!(xmlfile))
          sftp.file.open(datfile, "w") do |f|
            f.puts Marshal::dump(@data)
          end
        else
          @data = Marshal::load(sftp.download!(datfile))
        end
      rescue # datfile does not exists
        @data = Machine::parse_lshw_xml(sftp.download!(xmlfile))
        sftp.file.open(datfile, "w") do |f|
          f.puts Marshal::dump(@data)
        end
      end

    else # Machine object data are not retrieved from a remote server

      @data = Machine::parse_lshw_xml(args[:xmldata])

    end
  end

  def self.parse_lshw_xml(xmldata)

    # TODO: this method is overkill: change approach? stream parsing 
    # instead of tree parsing?

    doc = REXML::Document::new xmldata
    root = doc.root
    elems = doc.root.elements

    data                                  = {}

    ##################### CORE ##############################
    data[:name]                           = ckBogus(root.attributes["id"])
    data[:description]                    = ckBogus(elems["description"].text)
    begin
      data[:product]                      = ckBogus(elems["product"].text)
    rescue
      data[:product]                      = nil
    end
    data[:vendor]                         = ckBogus(elems["vendor"].text)
    data[:vendor]                         = ckBogus(elems["vendor"].text)
    data[:serial]                         = ckBogus(elems["serial"].text)

    begin
      data[:uuid]                         = \
        ckBogus(elems["configuration/setting[@id='uuid']"].attributes["value"])
    rescue
      data[:uuid]                         = nil
    end
    
    begin
      data[:chassis]                      = \
        ckBogus(elems["configuration/setting[@id='chassis']"].\
                attributes["value"])
    rescue
      data[:uuid]                         = nil
    end

    ##################### MOTHERBOARD #######################
    data[:mobo]                           = {}
    data[:mobo][:vendor]                  = \
      ckBogus(elems["node[@id='core']/vendor"].text)
    data[:mobo][:product]                 = \
      ckBogus(elems["node[@id='core']/product"].text)

    ##################### PROCESSOR #########################
    data[:cpu]                            = {}
    cpu                                   = \
      elems["node[@id='core']/node[@id='cpu']"]
    if (not cpu)
      cpu                                 = \
        elems["node[@id='core']/node[@id='cpu:0']"]
    end
    data[:cpu][:vendor]                   = cpu.elements["vendor"].text
    data[:cpu][:product]                  = cpu.elements["product"].text
    data[:cpu][:bits]                     = cpu.elements["width"].text

    ["clock", "size", "capacity"].each do |word|
      tmp_sym   = word.to_sym
      tmp_elem  = cpu.elements[word]
      if (not tmp_elem)
        data[:cpu][tmp_sym] = nil
        next
      end
      tmp_n     = tmp_elem.text.to_i
      tmp_u     = tmp_elem.attributes["units"]
      tmp_n = case tmp_u
                when "kHz" then tmp_n * 1000
                when "MHz" then tmp_n * 1000000
                else tmp_n
              end
      data[:cpu][tmp_sym]                 = tmp_n   # Always in Hz
    end

    ##################### MEMORY ############################
    data[:ram]                            = []
    doc.elements.each("node/node[@id='core']/node[@class='memory']/node[@class='memory']") do |slot|
      hash                                = {}
      next if slot.elements["description"] =~ /empty/i or !slot.elements["size"]
      # detected an empty slot: skipped: TODO: report it with :empty=>true ? 
      hash[:size]                         = slot.elements["size"].text 
      hash[:units]                        = \
                                      slot.elements["size"].attributes["units"]
      data[:ram].push hash
    end
  
    # TODO: various PCI devices: audio, video etc.

    ##################### NETWORK ###########################
    data[:net]                            = []
    [
      "node/node/node[@id='pci']/node[@id='network']",
      "node/node/node[@id='pci']/node/node[@class='network']",
      "node/node/node[@id='bridge']"
    ].each do |search_pattern|                        # TODO: ISA nework cards
      doc.elements.each(search_pattern) do |net|

        # Is there a valid MAC address? Check, but be tolerant: various
        # separator, not just ':', are allowed... or even *no* separator 
        # at all (see the "[ :\.,;-_]?" in the regexp) .
        tmp_mac_elm = net.elements["serial"]
        next unless tmp_mac_elm
        tmp_mac = tmp_mac_elm.text
        next unless tmp_mac =~ /([0-9a-f]{2}[ :\.,;-_]?){5}[0-9a-f]{2}/i

        hash                              = {}
        hash[:mac]                        = tmp_mac 
        hash[:logicalname]                = net.elements["logicalname"].text
        begin
          hash[:product]                  = net.elements["product"].text 
        rescue
          hash[:product]                  = nil
        end
        begin
          hash[:vendor]                   = net.elements["vendor"].text
        rescue
          hash[:vendor]                   = nil
        end
        data[:net].push hash
      end
    end
                            
    ##################### DISKS #############################
    data[:disks]                          = [] 
    [
      "node/node/node/node/node/node[@id='disk']",
      "node/node/node/node/node[@id='disk']",
      "node/node/node[@id='disk']"
    ].each do |search_pattern|                        
      doc.elements.each(search_pattern) do |disk|
        hash                              = {}
        hash[:desc]                       = disk.elements["description"].text 
        hash[:logicalname]                = disk.elements["logicalname"].text
        begin
          hash[:product]                  = disk.elements["product"].text 
        rescue
          hash[:product]                  = nil
        end
        begin
          hash[:vendor]                   = disk.elements["vendor"].text
        rescue
          hash[:vendor]                   = nil
        end
        begin
          hash[:serial]                   = disk.elements["serial"].text
        rescue
          hash[:serial]                   = nil
        end
        hash[:size]                       = {}
        begin
          hash[:size][:units]             = disk.elements["size"].\
                                              attributes["units"]
        rescue
          hash[:size][:units]             = nil
        end
        begin
          hash[:size][:value]             = disk.elements["size"].text
        rescue
          hash[:size][:value]             = nil
        end
        ################# PARTITIONS ##########################
        # TODO: partition/volume UUIDs? Patch lshw ;-) ?
        hash[:volumes]                    = []
        disk.elements.each("node[@class='volume']") do |vol|
          volume_hash                     = {}

          volume_hash[:businfo]           = vol.elements["businfo"].text
          volume_hash[:desc]              = vol.elements["description"].text
          volume_hash[:physid]            = vol.elements["physid"].text
          volume_hash[:logicalname]       = vol.elements["logicalname[1]"].text
          begin
            volume_hash[:mountpoint]      = vol.elements["logicalname[2]"].text
          rescue
            volume_hash[:mountpoint]      = nil
          end
          begin
            volume_hash[:serial]          = vol.elements["serial"].text
          rescue 
            volume_hash[:serial]          = nil
          end
          volume_hash[:capacity]          = vol.elements["capacity"].text
          
          ###################### LOGICAL PARTITIONS ########## 
          volume_hash[:logical_volumes]   = []
          vol.elements.each("node[@class='volume']") do |lvol|
            lvolume_hash                  = {}
            lvolume_hash[:desc]           = lvol.elements["description"].text
            lvolume_hash[:physid]         = lvol.elements["physid"].text
            lvolume_hash[:logicalname]    = lvol.elements["logicalname[1]"].text
            begin
              lvolume_hash[:mountpoint]   = lvol.elements["logicalname[2]"].text
            rescue
              lvolume_hash[:mountpoint]   = nil
            end
            lvolume_hash[:capacity]       = lvol.elements["capacity"].text

            volume_hash[:logical_volumes].push lvolume_hash
          end
          if volume_hash[:logical_volumes].length == 0
            volume_hash[:logical_volumes] = nil 
              # 'cause [] is not 'false' as a logical Ruby expression...
          end
          hash[:volumes].push volume_hash
        end

        data[:disks].push hash
      end
    end 
    
    return data

  end

  def compare_to(other_machine) 
    same_components = {

      # did not use boolean since we might need :partly or :maybe ;-)
      :same_uuid    => :no,
      :same_serial  => :no,
      :same_mobo    => :no,
      :same_cpu     => :no,

      :same_ram     => 0,   
      :same_disks   => 0, 
      :same_net     => 0 
    }
    
    # CORE
    if @data[:uuid] == nil or other_machine.data[:uuid] == nil
     same_components[:same_uuid] = :no
    else
      if @data[:uuid].casecmp( other_machine.data[:uuid] ) == 0
        same_components[:same_uuid] = :yes
      end
    end
    if @data[:serial] == nil or other_machine.data[:serial] == nil
     same_components[:same_serial] = :no
    else
      if @data[:serial].casecmp( other_machine.data[:serial] ) == 0
        same_components[:same_serial] = :yes
      end
    end

    # MOBO
    if not ( @data[:mobo][:product] and @data[:mobo][:vendor] )
      same_components[:same_mobo] = :no
    else
      if @data[:mobo][:product].casecmp( other_machine.data[:mobo][:product] ) == 0 and @data[:mobo][:vendor].casecmp( other_machine.data[:mobo][:vendor] ) == 0
        same_components[:same_mobo] = :yes
      end
    end
    
    # CPU 
      # normalize strings:
    tmp_str_product = @data[:cpu][:product].gsub(/\s/, "").downcase
    tmp_str_product_other =
      other_machine.data[:cpu][:product].gsub(/\s/, "").downcase 
    tmp_str_vendor = @data[:cpu][:vendor].gsub(/\s/, "").downcase
    tmp_str_vendor_other =
      other_machine.data[:cpu][:vendor].gsub(/\s/, "").downcase 

    if (@data[:cpu][:bits] == other_machine.data[:cpu][:bits] and
        tmp_str_product == tmp_str_product_other and
        tmp_str_vendor == tmp_str_vendor_other)
      same_components[:same_cpu] = :yes
    else
      same_components[:same_cpu] = :no
    end

    # RAM
      # TODO: handle different units (e.g. "bytes" and "kilobytes") (rare)
      # calling Array.how_many_in_common_rel e creating a suitable method
    same_components[:same_ram] = \
      @data[:ram].how_many_in_common(other_machine.data[:ram])

    # NET
    same_components[:same_net] = \
      @data[:net].how_many_in_common_rel(
        other_machine.data[:net], 
        proc{|a,b| a[:mac] == b[:mac]} 
      ) 

    # DISKS
    same_components[:same_disks] = \
      @data[:disks].how_many_in_common_rel(
        other_machine.data[:disks], 
        proc{|a,b| a[:serial] == b[:serial]} 
      ) 

     

    return same_components

  end

  private

  # Checks for bogus/meaningless informations such as 
  # "System Manufacturer" for the vendor name,
  # and return nil in that case
  def self.ckBogus(str) 
    [
      /^\s*$/,
      /123456789/,
      /System Name/i, /System Manufacturer/i
    ].each do |re|
      return nil if str =~ re
    end
    return str
  end

end


