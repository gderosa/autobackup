require 'partition'

class Disk

  attr_reader :kernel_id, :dev, :volumes, :size, :model

  def initialize(args)
    @kernel_id = args[:kernel_id]
    @dev = args[:dev]
    @size = args[:size]
    @volumes = []
    args[:volumes].each do |vol|
      @volumes << Partition.new(vol)
    end
    @model = args[:model]
  end

  # NOTE: you don't really need to 'sudo' commands dd and sfdisk.
  # Adding your normal user to the 'disk' system group will suffice.

  def backup_mbr(dir)
    system "dd if=#{@dev} of=#{dir}/mbr.bin bs=512 count=1 &> /dev/null"
  end

  def restore_mbr(dir)
    `dd if=#{dir}/mbr.bin of=#{@dev} bs=512 count=1 2> /dev/null`
  end

  def backup_ptable(dir)
    system "sfdisk #{@dev} -d > #{dir}/sfdisk-d"
  end

  def restore_ptable(dir)
    `sfdisk -f --no-reread #{@dev} < #{dir}/sfdisk-d 2> /dev/null`
  end

  def restore(disks, machine, dir, crypto_opts={}, *opts)
    # @ disks may be an array of Disk objects or just *a* Disk object
    
    raise TypeError, "disks cannot be ``nil'' or ``false''" unless disks

    if disks.class == Array # you must figure out which disk to restore from
      disks.each do |disk|
        if @kernel_id == disk.kernel_id
          return restore(disk, machine, dir, crypto_opts) 
        end
      end  
      return {:disk => nil, :state => :not_found_the_same_disk}
    end

    if disks.class != Disk        
      raise TypeError, "``disks'' should be of Disk class, not #{disks.class}"
    end

    disk = disks        # just one disk

    return {:disk => disk, :state => :no_ptable} \
      unless (compare_ptable(disk) or opts.include? :dont_check_ptable)

    machinedir = dir + "/" + machine.id    

    diskdir = machinedir + "/" + disk.kernel_id

    @volumes.each do |vol|
      mountpoint_save = nil
      vol.umount if (mountpoint_save = vol.mountpoint) 
      remote_volume = disk.volumes.detect{|x|x.pn==vol.pn}
      if remote_volume.respond_to? "fstype"
        begin
          vol.restore(
            diskdir + "/" + vol.pn.to_s,
            remote_volume.fstype,
            crypto_opts
          ) 
        rescue Errno::ENOENT
          STDERR.puts "\nCouldn't restore partition no. #{vol.pn}: image file not found"
          STDERR.puts "(if a backup was made, maybe it was not completed)"
        end
      end
      vol.mount(mountpoint_save) if mountpoint_save
    end

    return {:disk => disk, :state => :ok}

  end

  # NOTE: since Disk objects content is based on GNU parted output,
  # actual FS content is required...
  # TODO: part table should be grabbed from sfdisk, while just the
  # "real fs type" should be taken from parted; maybe fs type
  # should not be considered in compare_ptable; for now, :dont_check_ptable
  # option in Disk#restore has to be used if part. table has just been restored.
  
  def compare_ptable(disk)
    relation = proc do |vol1, vol2|
      vol1.size   == vol2.size  and
      vol1.fstype == vol2.fstype and
      vol1.pn     == vol2.pn
    end
    return disk.volumes.length == \
      disk.volumes.how_many_in_common_by(@volumes, relation) 
  end

end

