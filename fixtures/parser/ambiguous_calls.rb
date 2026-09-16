# These forms are intentionally similar-looking but use distinct Ruby grammar.
value = 12
half = value / 2
matcher = /item\d+/
puts matcher
puts /literal-regexp/
render value, half
