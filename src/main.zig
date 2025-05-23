const GPA = std.heap.smp_allocator;
var _WORD_ARENA = std.heap.ArenaAllocator.init(GPA);
const WORD_ARENA = _WORD_ARENA.allocator();

var STDERR = std.io.getStdErr().writer();
var STDOUT = std.io.getStdOut().writer();

fn isDelimiter(b: u8) bool
{
  switch (b) {
    '"', '\'', '*', '+', '-', '%', '\\', '/', ' ', ',', '(', ')', '[', 0, ']',
    '{', '}', '<', '>', '`', '|', '=', ':', ';', '\t', '\n', '\r'
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

// TODO use a UTF8 iterator, just discard invalid bytes
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
  while (n_read > 0) {
    for (read_buf.items[0..n_read]) |b| {
      if (isDelimiter(b)) {
        if (word_buf.items.len > 0) {
          try addWordToWordMap(word_map, word_buf.items[0..word_buf.items.len]);
          word_buf.clearRetainingCapacity();
        }
        if (!std.ascii.isWhitespace(b))
          try addWordToWordMap(word_map, &[1]u8{b});
      } else if (!std.ascii.isControl(b)) {
        try word_buf.append(b);
      }
    }
    n_read = try file_reader.read(read_buf.items);
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
  while (it.next()) |e| {
    try sorted_wordmap.append(e);
  }
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
    if (streq(arg, "--help")) {
      return help(program_name);
    }
    // "-" is stdin.
    var file = if (streq(arg, "-"))
      std.io.getStdIn()
    else
      try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
    // preallocate some memory based on a file size.
    const stat = try file.stat();
    const estimated_entries: u32 =
      @truncate(stat.size / @sizeOf(WordMap.KV) / 4);
    try word_map.ensureTotalCapacity(estimated_entries);
    try parseFileToWordMap(&scratch_arena, &word_map, &file);
  }
  try printWordMap(&word_map);
}

pub fn main() !void
{
  error_main() catch |err| {
    std.process.fatal("{any}.", .{ err });
  };
  std.process.cleanExit();
}

const std = @import("std");
