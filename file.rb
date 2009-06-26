
# While File.readlink behaves like the analogous shell command,
# File.readlink! behaves like 'readlink -f'

class File
                                          
  def File.readlink!(path)                
    path = File.expand_path(path)
    dirname = File.dirname(path)
    readlink = File.readlink(path)
    if not readlink =~ /^\//              # it's a relative path
      readlink = dirname + '/'+ readlink  # make it absolute
    end
    readlink = File.expand_path(readlink) # eliminate this/../../that
    if File.symlink?(readlink)           
      return File.readlink!(readlink)     # recursively follow symlinks
    else
      return readlink
    end
  end

end


