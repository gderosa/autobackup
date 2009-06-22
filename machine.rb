# Author::    Guido De Rosa  (mailto:job@guidoderosa.net)
# Copyright:: Copyright (C) 2009 Guido De Rosa
# License::   General Public License, version 2

require 'uuid'
require 'net/sftp'
require 'rexml/document'

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
    doc = REXML::Document::new xmldata
    root = doc.root
    elems = doc.root.elements

    data                                  = {}

    ##################### CORE ##############################
    data[:name]                           = ckBogus(root.attributes["id"])
    data[:description]                    = ckBogus(elems["description"].text)
    data[:product]                        = ckBogus(elems["product"].text)
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
    data[:cpu][:vendor]                   = \
      ckBogus(elems["node[@id='core']/node[@id='cpu']/vendor"].text)
    data[:cpu][:product]                  = \
      ckBogus(elems["node[@id='core']/node[@id='cpu']/product"].text)
    data[:cpu][:bits]                     = \
      ckBogus(elems["node[@id='core']/node[@id='cpu']/width"].text)
    data[:cpu][:clock]                    = {}
    data[:cpu][:clock][:value]            = \
      ckBogus(elems["node[@id='core']/node[@id='cpu']/clock"].text)
    data[:cpu][:clock][:units]            = \
      ckBogus(elems["node[@id='core']/node[@id='cpu']/clock"].\
              attributes["units"])

    ##################### MEMORY ############################
    data[:ram]                            = []
    doc.elements.each("node/node[@id='core']/node[@id='memory']/node") do |slot|
      hash                                = {}
      hash[:size]                         = slot.elements["size"].text 
      hash[:units]                        = 
                                      slot.elements["size"].attributes["units"]
      data[:ram].push hash
    end
  
    # TODO: various PCI devices: audio, video etc.

    ##################### NETWORK ###########################
    data[:net]                            = []
    [
      "node/node/node[@id='pci']/node[@id='network']",
      "node/node/node[@id='pci']/node/node[@id='network']"
    ].each do |search_pattern|                        # TODO: ISA nework cards
      doc.elements.each(search_pattern) do |net|
        hash                              = {}
        hash[:mac]                        = net.elements["serial"].text 
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
      "node/node/node/node[@id='ide']/node/node[@id='disk']",
      "node/node/node/node[@id='storage']/node[@id='disk']"
    ].each do |search_pattern|                        
      doc.elements.each(search_pattern) do |disk|
        hash                              = {}
        hash[:desc]                       = disk.elements["description"].text 
        hash[:logicalname]                = disk.elements["logicalname"].text
        hash[:product]                    = disk.elements["product"].text 
        hash[:vendor]                     = disk.elements["vendor"].text
        hash[:serial]                     = disk.elements["serial"].text
        hash[:size]                       = {}
        hash[:size][:units]               = disk.elements["size"].attributes["units"]
        hash[:size][:value]               = disk.elements["size"].text
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

  private

  # Checks for bogus/meaningless informations such as 
  # "System Manufacturer" for the vendor name,
  # and return nil in that case
  def self.ckBogus(str) 
    [
      /123456789/,
      /System Name/i, /System Manufacturer/i
    ].each do |re|
      return nil if str =~ re
    end
    return str
  end

end


