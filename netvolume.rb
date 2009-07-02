require 'partition'

class NetVolume < Partition
  attr_reader :dev, :fstype, :mountpoint

  Mount_base = "/mnt/ssh"

  def backup
    # do nothing, for now
  end

  def mount(mountpoint="#{Mount_base}/#@dev")

    File.makedirs(mountpoint) unless File.directory?(mountpoint)
    if @fstype =~ /fuse\.ssh/
      if system("sshfs #@dev #{mountpoint}")
        @mountpoint = mountpoint
        return true
      else
        return false
      end
    else
      return false
    end
  end

end
