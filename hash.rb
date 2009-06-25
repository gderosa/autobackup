class Hash
  def sum
    s = 0
    self.each_value do |elem|
      s += elem
    end
    return s
  end
end
