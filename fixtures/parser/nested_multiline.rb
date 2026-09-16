records.each do |record|
  record.fetch(:items).each do |item|
    if item[:active]
      total = item[:value] + 1
      puts total
    else
      warn "inactive: #{item[:name]}"
    end
  end
end

