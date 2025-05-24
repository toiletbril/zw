var _GPA = std.heap.GeneralPurposeAllocator(.{}).init;
const GPA = _GPA.allocator();

var STDERR = std.io.getStdErr().writer();
var STDOUT = std.io.getStdOut().writer();

fn isDelimiter(b: u8) bool
{
  switch (b) {
    '"', '\'', '*', '+', '-', '%', '\\', '/', ' ', ',', '(', ')', '[', ']', '{',
    '}', '<', '>', '`', '|', '=', ':', ';', '\t', '\n', '\r', 0
      => return true,
    else => return false,
  }
}

const WordMap = std.StringHashMap(u64);

fn addWordToWordMap(word_map: *WordMap, word: []const u8) !void
{
  const actual_word = try GPA.dupe(u8, word);
  const entry = try word_map.getOrPutValue(actual_word, 0);
  entry.value_ptr.* += 1;
}

fn parseFileToWordMap(scratch_arena: *std.heap.ArenaAllocator,
                      word_map: *WordMap, file: *std.fs.File) !void
{
  defer _ = scratch_arena.reset(.retain_capacity);
  const scratch_allocator = scratch_arena.allocator();
  var read_buf = std.ArrayList(u8).init(scratch_allocator);
  try read_buf.resize(std.heap.pageSize());
  var word_buf = try std.ArrayList(u8).initCapacity(scratch_allocator, 16);
  var file_reader = std.io.bufferedReader(file.reader());
  var n_read = try file_reader.read(read_buf.items);
  var truncated_buf: [3]u8 = undefined;
  var truncated_cp_sz = @as(u3, 0);
  while (n_read > 0) {
    var cp_start = @as(u64, 0);
    while (cp_start < n_read) {
      // 1. find out codepoint length.
      const cp_sz =
        std.unicode.utf8ByteSequenceLength(read_buf.items[cp_start]) catch {
          cp_start += 1;
          continue;
        };
      std.debug.assert(cp_sz <= 4);
      const cp_end = cp_start + cp_sz;
      // special case: codepoint was truncated and is partially present.
      // remember the initial part and get out.
      if (cp_end > n_read) {
        std.debug.assert(cp_sz <= 3);
        @memcpy(&truncated_buf, read_buf.items[cp_start..]);
        truncated_cp_sz = cp_sz;
        break;
      }
      // 2. retrieve the codepoint.
      const cp = read_buf.items[cp_start..cp_end];
      // 3. validate the codepoint.
      if (!std.unicode.utf8ValidateSlice(cp)) {
        cp_start += 1;
        continue;
      }
      // 4. check whether codepoint is a delimiter.
      if (isDelimiter(cp[0])) {
        // add a word we collected to the word map.
        if (word_buf.items.len > 0) {
          try addWordToWordMap(word_map, word_buf.items[0..word_buf.items.len]);
          word_buf.clearRetainingCapacity();
        }
        // add this delimiter as well.
        if (!std.ascii.isWhitespace(cp[0]) and !std.ascii.isControl(cp[0]))
          try addWordToWordMap(word_map, cp[0..1]);
      } else if (!std.ascii.isControl(cp[0])) {
        // append this codepoint to word buffer.
        try word_buf.appendSlice(cp);
      }
      cp_start += cp_sz;
    }
    // read again. if the truncated buffer is not empty, put's it's contents in
    // the beginning.
    n_read = try file_reader.read(read_buf.items[truncated_cp_sz..]);
    if (truncated_cp_sz > 0) {
      @memcpy(read_buf.items, truncated_buf[0..truncated_cp_sz]);
      truncated_cp_sz = 0;
    }
  }
}

fn compareWordMapEntry(_: void, a: WordMap.Entry, b: WordMap.Entry) bool
{
  return a.value_ptr.* < b.value_ptr.*;
}

fn sortWordMapEntries(word_map: *const WordMap) !std.ArrayList(WordMap.Entry)
{
  var it = word_map.iterator();
  var sorted_wordmap = std.ArrayList(WordMap.Entry).init(GPA);
  while (it.next()) |e| try sorted_wordmap.append(e);
  std.mem.sort(WordMap.Entry, sorted_wordmap.items, {}, compareWordMapEntry);
  return sorted_wordmap;
}

fn printWordMap(word_map: *WordMap) !void
{
  const sorted_wordmap = try sortWordMapEntries(word_map);
  defer sorted_wordmap.deinit();
  var stdout = std.io.bufferedWriter(STDOUT);
  var total_count = @as(u64, 0);
  for (sorted_wordmap.items) |e| {
    _ = try stdout.writer()
                  .print("{}\t\t{s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    total_count += e.value_ptr.*;
  }
  _ = try stdout.writer().print("{}\n", .{ total_count });
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
    , .{ program_name })
    catch unreachable;
}

fn streq(a: []const u8, b: []const u8) bool
{
  return std.mem.eql(u8, a, b);
}

fn error_main() !void
{
  var word_map = WordMap.initContext(GPA, .{});
  defer word_map.deinit();
  var scratch_arena = std.heap.ArenaAllocator.init(GPA);
  var args = try std.process.argsWithAllocator(GPA);
  // skip program name.
  const program_name = args.next().?;
  while (args.next()) |arg| {
    if (streq(arg, "--help")) return help(program_name);
    // "-" is stdin.
    var file = if (streq(arg, "-"))
      std.io.getStdIn()
    else
      try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
    // preallocate some memory based on a file size.
    const stat = try file.stat();
    const estimated_entries: u32 =
      @truncate(stat.size / @sizeOf(WordMap.Entry) / 4);
    try word_map.ensureTotalCapacity(estimated_entries);
    try parseFileToWordMap(&scratch_arena, &word_map, &file);
  }
  try printWordMap(&word_map);
}

pub fn main() !void
{
  error_main() catch |err| std.process.fatal("{any}.", .{ err });
  std.process.cleanExit();
}

const std = @import("std");
