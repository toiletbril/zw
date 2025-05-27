var _GPA = std.heap.GeneralPurposeAllocator(.{}).init;
const GPA = _GPA.allocator();

var STDERR = std.io.getStdErr().writer();
var STDOUT = std.io.getStdOut().writer();

const ASCII_DELIMS = [_]u8{
  '"', '\'', '*', '+', '%', '\\', '/', ' ', ',', '(', ')', '[', ']', '{',
  '}', '<', '>', '`', '|', '=', ':', ';', '\t', '\n', '\r', 0,
};

fn isDelimiter(b: u8) bool
{
  if (std.mem.indexOfScalar(u8, &ASCII_DELIMS, b)) |_| return true;
  return false;
}

const WordMapContext = struct {
  const Hash = std.hash.RapidHash;
  pub fn hash(_: @This(), key: []const u8) u64
  {
    return Hash.hash(0, key);
  }
  pub fn eql(_: @This(), a: []const u8, b: []const u8) bool
  {
    return std.mem.eql(u8, a, b);
  }
};

const WordMap = std.HashMap([]const u8, u64, WordMapContext, 99);

fn addWordToWordMap(word_arena: *std.heap.ArenaAllocator,
                    word_map: *WordMap, word: []const u8) !void
{
  const actual_word = try word_arena.allocator().dupe(u8, word);
  const entry = try word_map.getOrPutValue(actual_word, 0);
  entry.value_ptr.* += 1;
}

fn parseFileToWordMap(word_arena: *std.heap.ArenaAllocator,
                      scratch_arena: *std.heap.ArenaAllocator,
                      word_map: *WordMap,
                      file_reader: *std.io.AnyReader) !void
{
  defer _ = scratch_arena.reset(.retain_capacity);
  const scratch_allocator = scratch_arena.allocator();

  var read_buf = std.ArrayList(u8).init(scratch_allocator);
  try read_buf.resize(std.heap.pageSize() * 64);

  var word_buf = try std.ArrayList(u8).initCapacity(scratch_allocator, 16);
  var n_read = try file_reader.read(read_buf.items);
  var truncated_buf: [3]u8 = undefined;
  var truncated_cp_sz = @as(u3, 0);

  // comptime simd constants.
  const lane_width = 16;
  const SimdLane = comptime @Vector(lane_width, u8);
  const ascii_mask: SimdLane = comptime @splat(0x80);
  // build one splat per delimiter once.
  comptime var delim_splats: [ASCII_DELIMS.len]SimdLane = undefined;
  comptime {
    for (&delim_splats, ASCII_DELIMS) |*dst, c| dst.* = @splat(c);
  }

  while (n_read > 0) {
    var buf_idx = @as(u64, 0);

    while (buf_idx < n_read) {
      // simd ascii path.
      if (std.ascii.isAscii(read_buf.items[buf_idx]) and
          buf_idx + lane_width < n_read)
      ascii: {
        // load a lane.
        const lane: *align(1) const SimdLane =
          @ptrCast(read_buf.items.ptr + buf_idx);
        const lane_end = buf_idx + lane_width;

        // make sure the entire lane is ascii.
        if (@reduce(.Or, lane.* & ascii_mask) != 0) break :ascii;

        var mask: u16 = 0; // must match lane_width.
        // build delimiter mask OR-ing every comparison.
        inline for (delim_splats) |d| mask |= @bitCast(lane.* == d);
        if (mask == 0) {
          // hooray, no delimiters in lane. append the entire buffer.
          try word_buf.appendSlice(read_buf.items[buf_idx..lane_end]);
          buf_idx += lane_width;
          continue;
        }

        // slow-path: walk the 16 bytes, guided by the mask.
        var lane_idx: u8 = 0;
        var prev_buf_idx: u64 = buf_idx;

        while (lane_idx < lane_width) : ({ mask >>= 1; lane_idx += 1; }) {
          // wait for the delimiter.
          if (mask & 1 == 0) continue;

          const lane_off = buf_idx + lane_idx;
          std.debug.assert(prev_buf_idx <= lane_off);

          try word_buf.appendSlice(read_buf.items[prev_buf_idx..lane_off]);
          if (word_buf.items.len != 0) {
            try addWordToWordMap(word_arena, word_map, word_buf.items);
            word_buf.clearRetainingCapacity();
          }

          const byte = read_buf.items[lane_off];

          // append the delimiter itself.
          if (!std.ascii.isWhitespace(byte) and !std.ascii.isControl(byte))
            try addWordToWordMap(word_arena, word_map, &[1]u8{byte});
          prev_buf_idx = lane_off + 1;
        }

        if (prev_buf_idx < lane_end)
          try word_buf.appendSlice(read_buf.items[prev_buf_idx..lane_end]);

        buf_idx += lane_width;

        continue;
      }

      // scalar/unicode path.

      // 1. find out codepoint length.
      const cp_sz =
        std.unicode.utf8ByteSequenceLength(read_buf.items[buf_idx]) catch {
          buf_idx += 1;
          continue;
        };
      std.debug.assert(cp_sz <= 4);
      const cp_end = buf_idx + cp_sz;
      // special case: codepoint was truncated and is partially present.
      // remember the initial part and get out.
      if (cp_end > n_read) {
        @memcpy(
          truncated_buf[0..n_read-buf_idx], read_buf.items[buf_idx..n_read]);
        truncated_cp_sz = cp_sz;
        break;
      }

      // 2. retrieve the codepoint.
      const cp = read_buf.items[buf_idx..cp_end];
      // 3. validate the codepoint.
      if (!std.unicode.utf8ValidateSlice(cp)) {
        buf_idx += 1;
        continue;
      }

      // 4. check whether codepoint is a delimiter.
      if (isDelimiter(cp[0])) {
        // add a word we collected to the word map.
        if (word_buf.items.len > 0) {
          try addWordToWordMap(word_arena, word_map, word_buf.items);
          word_buf.clearRetainingCapacity();
        }
        // add this delimiter as well.
        if (!std.ascii.isWhitespace(cp[0]) and !std.ascii.isControl(cp[0]))
          try addWordToWordMap(word_arena, word_map, cp[0..1]);
      } else if (!std.ascii.isControl(cp[0])) {
        // or append this codepoint to word buffer.
        try word_buf.appendSlice(cp);
      }

      buf_idx += cp_sz;
    }

    // read again. if the truncated buffer is not empty, put's it's contents in
    // the beginning.
    n_read = try file_reader.read(read_buf.items[truncated_cp_sz..]);

    if (truncated_cp_sz > 0) {
      @memcpy(
        read_buf.items[0..truncated_cp_sz], truncated_buf[0..truncated_cp_sz]);
      truncated_cp_sz = 0;
    }
  }

  if (word_buf.items.len > 0)
    try addWordToWordMap(word_arena, word_map, word_buf.items);
}

fn compareWordMapEntry(_: void, a: WordMap.Entry, b: WordMap.Entry) bool
{
  return a.value_ptr.* < b.value_ptr.*;
}

fn sortWordMapEntries(scratch_arena: *std.heap.ArenaAllocator,
                      word_map: *const WordMap) !std.ArrayList(WordMap.Entry)
{
  var it = word_map.iterator();
  var sorted_wordmap =
    std.ArrayList(WordMap.Entry).init(scratch_arena.allocator());
  while (it.next()) |e| try sorted_wordmap.append(e);
  std.mem.sort(WordMap.Entry, sorted_wordmap.items, {}, compareWordMapEntry);
  return sorted_wordmap;
}

fn printWordMap(scratch_arena: *std.heap.ArenaAllocator,
                word_map: *WordMap) !void
{
  const sorted_wordmap = try sortWordMapEntries(scratch_arena, word_map);
  defer _ = scratch_arena.reset(.retain_capacity);

  var stdout = std.io.bufferedWriter(STDOUT);
  var total_count = @as(u64, 0);
  var stdout_writer = stdout.writer();

  for (sorted_wordmap.items) |e| {
    _ = try stdout_writer
                  .print("{}\t\t{s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    total_count += e.value_ptr.*;
  }
  _ = try stdout_writer.print("{}\n", .{ total_count });

  try stdout.flush();
}

fn help(program_name: [:0]const u8) !void
{
  STDERR.print(
\\USAGE
\\  {s} [-OPTIONS] <file1> [, file2, ..]
\\  Extract count of each word from a file. If file is "-", use standard input.
\\
\\OPTIONS
\\      --help                      Display help message.
\\
    , .{ program_name }) catch unreachable;
}

fn streq(a: []const u8, b: []const u8) bool
{
  return std.mem.eql(u8, a, b);
}

fn error_main() !void
{
  var word_map = WordMap.init(GPA);
  defer word_map.deinit();

  var scratch_arena = std.heap.ArenaAllocator.init(GPA);
  defer scratch_arena.deinit();
  var word_arena = std.heap.ArenaAllocator.init(GPA);
  defer word_arena.deinit();
  var args = try std.process.argsWithAllocator(GPA);
  defer args.deinit();
  // skip program name.
  const program_name = args.next().?;
  var all_files_size: u128 = 0;

  while (args.next()) |arg| {
    if (streq(arg, "--help")) return help(program_name);

    // "-" is stdin.
    var file = if (streq(arg, "-"))
      std.io.getStdIn()
    else
      try std.fs.cwd().openFile(arg, .{ .mode = .read_only });

    defer file.close();

    const average_word_size = 8;
    const average_word_repetitions = 32;

    all_files_size += (try file.stat()).size;

    // preheat the map.
    const estimated_map_length: u32 =
      @truncate(all_files_size / average_word_size / average_word_repetitions);
    try word_map.ensureTotalCapacity(estimated_map_length);

    // preheat the arena.
    if (word_arena.queryCapacity() < all_files_size) {
      const wa = word_arena.allocator();
      const estimated_arena_size: usize =
        @truncate(all_files_size / average_word_repetitions);
      wa.free(try wa.alloc(u8, estimated_arena_size));
    }

    var any_file_reader = file.reader().any();
    try parseFileToWordMap(&word_arena, &scratch_arena, &word_map,
                           &any_file_reader);
  }

  try printWordMap(&scratch_arena, &word_map);
}

pub fn main() !void
{
  error_main() catch |err| std.process.fatal("{any}.", .{ err });
  std.process.cleanExit();
}

const std = @import("std");
