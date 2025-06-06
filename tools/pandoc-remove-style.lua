function RawBlock(el)
  -- Remove <style> blocks
  if el.format:match("html") then
    if el.text:match("<style") then
      return {}
    end
  end
end

function RawInline(el)
  -- Remove inline <style> (rare, but possible)
  if el.format:match("html") then
    if el.text:match("<style") then
      return {}
    end
  end
end
