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

  def backup_mbr(dir)
    system "dd if=#{@dev} of=#{dir}/mbr.bin bs=512 count=1 &> /dev/null"
  end

  def restore_mbr(dir)
    system "dd if=#{dir}/mbr.bin of=#{@dev} bs=512 count=1 &> /dev/null"
  end

  def backup_ptable(dir)
    system "sfdisk #{@dev} -d > #{dir}/sfdisk-d"
  end

  def restore_ptable(dir)
    system "sfdisk #{@dev} < #{dir}/sfdisk-d"
  end

  def restore(disks, machine, dir, *opts)
    # @ disks may be an array of Disk objects or just *a* Disk object
    
    raise TypeError, "disks cannot be ``nil'' or ``false''" unless disks

    if disks.class == Array # you must figure out which disk to restore from
      disks.each do |disk|
	if @kernel_id == disk.kernel_id
	  return restore(disk, machine, dir) 
	end
      end	
      return {:disk => nil, :state => :not_found_the_same_disk}
    end

    if disks.class != Disk		    
      raise TypeError, "``disks'' should be of Disk class, not #{disks.class}"
    end

    disk = disks				# just one disk

    return {:disk => disk, :state => :no_ptable} \
      unless (compare_ptable(disk) or opts.include? :dont_check_ptable)

    machinedir = dir + "/" + machine.id    

    diskdir = machinedir + "/" + disk.kernel_id

    puts "OK I'M DOING THE ACTUAL RESTORE ;-)" 

    return {:disk => disk, :state => :ok}

  end

  def compare_ptable(disk)

    relation = proc do |vol1, vol2|
      vol1.size	  == vol2.size	and
      vol1.fstype == vol2.fstype and
      vol1.pn	  == vol2.pn
    end

    return disk.volumes.length == \
      disk.volumes.how_many_in_common_rel(@volumes, relation)

  end

end

