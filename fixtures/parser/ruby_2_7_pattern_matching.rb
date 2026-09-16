# Ruby 2.7+: structural pattern matching.
case payload
in { name: String, enabled: true }
  name
else
  :invalid
end
