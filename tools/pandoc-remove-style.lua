function RawBlock(el)
  if el.format:match("html") then
    -- Remove <style> blocks
    if el.text:match("<style") then
      return {}
    end
    -- Remove prettier-ignore comments (empty after pandoc strips link refs)
    if el.text:match("prettier%-ignore") then
      return {}
    end
  end
end

function RawInline(el)
  if el.format:match("html") then
    -- Remove inline <style> (rare, but possible)
    if el.text:match("<style") then
      return {}
    end
    if el.text:match("prettier%-ignore") then
      return {}
    end
  end
end
