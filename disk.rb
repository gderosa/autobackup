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
    system "dd if=#{@dev} of=#{dir}/mbr.bin bs=512 count=1 > /dev/null"
  end

  def restore_mbr(dir)
    system "dd if=#{dir}/mbr.bin of=#{@dev} bs=512 cout=1 > /dev/null"
  end

  def backup_ptable(dir)
    system "sfdisk #{@dev} -d > #{dir}/sfdisk-d"
  end

  def restore_ptable(dir)
    system "sfdisk #{@dev} < #{dir}/sfdisk-d"
  end

  def restore(disks, machine, dir)
    return false unless disks

    if disks.class == Array # you must figure out which disk to restore from
      disks.each do |disk|
	if @kernel_id == disk.kernel_id
	  return restore(disk, machine, dir) 
	end
      end	
      return false
    end
    
    return false if disks.class != Disk # no duck typing here ;-/

    backup_disk = disks			# just one disk

    machinedir = dir + machine.id    

  end
end

