pub const phase1_constructs = @embedFile("parser/phase1_constructs.rb");
pub const nested_multiline = @embedFile("parser/nested_multiline.rb");
pub const ambiguous_calls = @embedFile("parser/ambiguous_calls.rb");
pub const ruby_2_7_pattern_matching = @embedFile("parser/ruby_2_7_pattern_matching.rb");
pub const invalid_unclosed_definition = @embedFile("parser/invalid_unclosed_definition.rb");

test "embedded Ruby parser fixtures are non-empty" {
    inline for ([_][]const u8{ phase1_constructs, nested_multiline, ambiguous_calls, ruby_2_7_pattern_matching, invalid_unclosed_definition }) |source| {
        if (source.len == 0) return error.EmptyFixture;
    }
}
