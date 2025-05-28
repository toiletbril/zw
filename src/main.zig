// Copyright (c) 2025 toiletbril. All rights reserved.
// Use of this source code is governed by a GPLv3 license that can be
// found in the LICENSE file in top directory.

// SIMD-accelerated word counter.
// Extracts count of each word from a file. A word is consists of either ASCII
// or Unicode. Binary is ignored.

var RAW_ALLOCATOR = std.heap.raw_c_allocator;

var STDERR = std.io.getStdErr().writer();
var STDOUT = std.io.getStdOut().writer();

// TODO this is overcomplicated.
// i almost allowed myself to like Zig, but suddenly
// https://github.com/ziglang/zig/issues/2647.
const ErrorStack = struct {
  var buf_offset: u64 = 0;
  var buf: [1024]u8 = std.mem.zeroes([1024]u8);

  fn print(_: @This(), comptime fmt: []const u8, args: anytype) void
  {
    const s = std.fmt.bufPrint(
      ErrorStack.buf[buf_offset..], fmt, args) catch unreachable;
    buf_offset += s.len;
  }

  pub fn putError(self: @This(), comptime fmt: []const u8, args: anytype,
                    msg: []const u8) void
  {
    self.print("got error while ", .{});
    self.print(fmt, args);
    self.print(": {s}.\n", .{ msg });
  }

  fn swapContextAndError(_: @This(), err_end: u64) void
  {
    var b = &ErrorStack.buf;
    const ctx_end = buf_offset - err_end;
    // put the error before end.
    @memcpy(b[b.len-err_end..], b[0..err_end]);
    // put context in the beginning.
    @memcpy(b[0..ctx_end], b[err_end..buf_offset]);
    // put the error after the context.
    @memcpy(b[ctx_end..ctx_end+err_end], b[b.len-err_end..]);
    // leave no trace behind.
    @memset(b[b.len-err_end..], 0);
  }

  pub fn putContext(self: @This(),
                      comptime fmt: []const u8, args: anytype) void
  {
    const e = ErrorStack.buf_offset;
    self.print("when ", .{});
    self.print(fmt, args);
    self.print(", ", .{});
    self.swapContextAndError(e);
  }

  pub fn getLogBuffer(_: @This()) []const u8
  {
    return &ErrorStack.buf;
  }
};

var ERROR_LOG: ErrorStack = .{};

fn describeStdError(err: anyerror) []const u8
{
  return switch (err) {
    error.OutOfMemory => "Out of memory",
    error.FileNotFound => "No such file or directory",
    error.IsDir => "Is a directory",
    else => "Unknown" // unhandled error :(
  };
}

fn fail(err: anyerror, comptime fmt: []const u8, args: anytype) error{ Handled }
{
  @branchHint(.cold);
  switch (err) {
    // do nothing if we failed already.
    error.Handled => {},
    // add context.
    error.NeedsContext => ERROR_LOG.putContext(fmt, args),
    // ordinary path.
    else => ERROR_LOG.putError(fmt, args, describeStdError(err)),
  }
  return error.Handled;
}

fn failButNeedsContext(err: anyerror, comptime fmt: []const u8,
                       args: anytype) error{ NeedsContext }
{
  @branchHint(.cold);
  _ = fail(err, fmt, args) catch {};
  return error.NeedsContext;
}

// TODO make a list of delimiters configurable at runtime.
const ASCII_DELIMS = [_]u8{
  '"', '\'', '*', '+', '%', '\\', '/', ' ', ',', '.', '(', ')', '[', ']', '{',
  '}', '<', '>', '`', '|', '=', ':', ';', '&', '^', '\t', '\n', '\r', 0,
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
  const actual_word = word_arena.allocator().dupe(u8, word) catch |err| {
    return fail(err, "copying word to the hash map", .{});
  };
  // NOTE the call below consumes ~50% of the entire runtime =D
  const word_entry = word_map.getOrPutValue(actual_word, 0) catch |err| {
    return fail(err, "growing the hash map", .{});
  };
  word_entry.value_ptr.* += 1;
}

fn cpuSupports(feature: std.Target.x86.Feature) bool
{
  return std.Target.x86.featureSetHas(builtin.cpu.features, feature);
}

// TODO improve the parsing of binary files.
// TODO multithreading.
// TODO low-memory path.

// Doesn't handle read errors by itself.
fn parseFileToWordMap(word_arena: *std.heap.ArenaAllocator,
                      scratch_arena: *std.heap.ArenaAllocator,
                      word_map: *WordMap,
                      file_reader: *std.io.AnyReader) !void
{
  defer _ = scratch_arena.reset(.retain_capacity);
  const scratch_allocator = scratch_arena.allocator();

  var read_buf = std.ArrayList(u8).init(scratch_allocator);
  try read_buf.resize(std.heap.pageSize() * 256); // a MB or more

  var word_buf =
    std.ArrayList(u8).initCapacity(scratch_allocator, 32) catch |err| {
      return fail(err, "initializing a temporary array for reading", .{});
    };
  var n_read = file_reader.read(read_buf.items) catch |err| {
    return failButNeedsContext(err, "reading a file", .{});
  };
  var truncated_buf: [3]u8 = undefined;
  var truncated_cp_sz = @as(u3, 0);

  // prepare for takeoff.
  const ct_lane_width =
    comptime if (cpuSupports(.avx512bw)) 64
    else if (cpuSupports(.avx2)) 32
    else if (cpuSupports(.sse4_2)) 16
    else 8;
  const SimdMask =
    comptime switch (ct_lane_width) {
      64 => u64,
      32 => u32,
      16 => u16,
      else => u8,
    };
  const SimdLane = comptime @Vector(ct_lane_width, u8);

  const ct_ascii_mask: SimdLane = comptime @splat(0x80);
  // build one splat per delimiter.
  comptime var ct_delim_splats: [ASCII_DELIMS.len]SimdLane = undefined;
  comptime {
    for (&ct_delim_splats, ASCII_DELIMS) |*dst, c| dst.* = @splat(c);
  }

  while (n_read > 0) {
    var buf_idx = @as(u64, 0);
    while (buf_idx < n_read) {
      // simd ascii path. fast if the entire lane is ascii, even faster if it's
      // without any delimiters.
      if (std.ascii.isAscii(read_buf.items[buf_idx]) and
          buf_idx + ct_lane_width < n_read)
      ascii: {
        // load a lane.
        const lane: *align(1) const SimdLane =
          @ptrCast(read_buf.items.ptr + buf_idx);
        const lane_end = buf_idx + ct_lane_width;

        // make sure the entire lane is ascii.
        if (@reduce(.Or, lane.* & ct_ascii_mask) != 0) break :ascii;
        // build a delimiter mask.
        var delimiter_mask: SimdMask = 0;
        inline for (ct_delim_splats) |d|
          delimiter_mask |= @bitCast(lane.* == d);
        if (delimiter_mask == 0) {
          // no delimiters in lane! append the entire buffer.
          word_buf.appendSlice(read_buf.items[buf_idx..lane_end]) catch |err| {
            return fail(err, "while reallocating temporary word buffer", .{});
          };
          buf_idx += ct_lane_width;
          continue;
        }

        // slow path: walk the 16 bytes manually.
        var lane_idx: u8 = 0;
        var prev_buf_idx: u64 = buf_idx;

        while (lane_idx < ct_lane_width)
          : ({ delimiter_mask >>= 1; lane_idx += 1; })
        {
          // wait for the delimiter.
          if (delimiter_mask & 1 == 0) continue;
          const lane_off = buf_idx + lane_idx;
          std.debug.assert(prev_buf_idx <= lane_off);
          // append the word.
          word_buf.appendSlice(
            read_buf.items[prev_buf_idx..lane_off]) catch |err| {
              return fail(err, "while reallocating temporary word buffer", .{});
            };
          if (word_buf.items.len != 0) {
            try addWordToWordMap(word_arena, word_map, word_buf.items);
            word_buf.clearRetainingCapacity();
          }
          const byte = read_buf.items[lane_off];
          // append the delimiter itself.
          if (!std.ascii.isWhitespace(byte) and !std.ascii.isControl(byte)) {
            try addWordToWordMap(word_arena, word_map, &[1]u8{byte});
          }
          prev_buf_idx = lane_off + 1;
        }

        if (prev_buf_idx < lane_end) {
          word_buf.appendSlice(
            read_buf.items[prev_buf_idx..lane_end]) catch |err| {
              return fail(err, "while reallocating temporary word buffer", .{});
            };
        }
        buf_idx += ct_lane_width;

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
        word_buf.appendSlice(cp) catch |err| {
          return fail(err, "while reallocating temporary word buffer", .{});
        };
      }

      buf_idx += cp_sz;
    }
    // read again.
    n_read = file_reader.read(read_buf.items[truncated_cp_sz..]) catch |err| {
      return failButNeedsContext(err, "reading a file", .{});
    };
    // if the truncated buffer is not empty, put's it's contents in the
    // beginning.
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
  while (it.next()) |e| sorted_wordmap.append(e) catch |err| {
    return fail(err, "sorting the hashmap", .{});
  };
  std.mem.sort(WordMap.Entry, sorted_wordmap.items, {}, compareWordMapEntry);
  return sorted_wordmap;
}

pub fn veryBufferedWriter(file: anytype)
  std.io.BufferedWriter(std.heap.pageSize() * 16, @TypeOf(file))
{
  return .{ .unbuffered_writer = file };
}

fn printWordMap(scratch_arena: *std.heap.ArenaAllocator,
                word_map: *WordMap) !void
{
  const sorted_wordmap = try sortWordMapEntries(scratch_arena, word_map);
  defer _ = scratch_arena.reset(.retain_capacity);

  var out = veryBufferedWriter(STDOUT);
  var out_writer = out.writer();

  var total_count = @as(u64, 0);
  var total_word_count = @as(u64, 0);
  for (sorted_wordmap.items) |e| {
    _ = out_writer.print(
      "{: <16} {s}\n", .{ e.value_ptr.*, e.key_ptr.* }) catch |err| {
        return fail(err, "writing to stdout", .{});
      };
    total_word_count += 1;
    total_count += e.value_ptr.*;
  }
  _ = out_writer.print(
    "{: <16} {}\n", .{ total_count, total_word_count }) catch |err| {
      return fail(err, "writing to stdout", .{});
    };

  try out.flush();
}

fn help(program_name: [:0]const u8) !void
{
  STDERR.print(
\\USAGE
\\  {s} [-OPTIONS] [file1, file2, ..]
\\  Extract count of each word from a file. When no file specified, or if the
\\  file is "-", use standard input.
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

// TODO proper cli options.
fn entry() !void
{
  var word_map = WordMap.init(RAW_ALLOCATOR);
  defer word_map.deinit();

  var scratch_arena = std.heap.ArenaAllocator.init(RAW_ALLOCATOR);
  defer scratch_arena.deinit();
  var word_arena = std.heap.ArenaAllocator.init(RAW_ALLOCATOR);
  defer word_arena.deinit();
  var args = std.process.argsWithAllocator(RAW_ALLOCATOR) catch |err| {
    fail(err, "allocating memory for CLI args", .{});
  };
  defer args.deinit();
  // skip program name.
  const program_name = args.next().?;
  var all_files_size: u128 = 0;
  var is_first_file = true;

  while (true) {
    var file_name: []const u8 = undefined;
    if (args.next()) |arg| {
      file_name = arg;
    } else if (is_first_file) {
      // first iteration and no arguments -- use stdin.
      file_name = "-";
    } else {
      break;
    }
    is_first_file = false;

    if (streq(file_name, "--help")) return help(program_name);

    // "-" is stdin.
    var file =
      if
        (streq(file_name, "-")) std.io.getStdIn()
      else
        std.fs.cwd().openFile(file_name, .{ .mode = .read_only })
          catch |err| {
            return fail(err, "opening `{s}`", .{ file_name });
          };

    defer file.close();
    std.log.debug("file is: '{s}'", .{ file_name });

    // proper values below affect the speed heavily.
    const average_word_size = 8;
    const average_word_repetitions = 32;

    all_files_size += (try file.stat()).size;
    std.log.debug("total file size: {}", .{ all_files_size });

    // preheat the map.
    const estimated_map_length: u32 =
      @truncate(all_files_size / average_word_size / average_word_repetitions);
    word_map.ensureTotalCapacity(estimated_map_length) catch |err| {
      return fail(err, "increasing hashmap capacity", .{});
    };
    std.log.debug("map capacity: {}", .{ word_map.capacity() });

    // preheat the arena.
    if (word_arena.queryCapacity() < all_files_size) {
      const wa = word_arena.allocator();
      const estimated_arena_size: usize =
        @truncate(all_files_size / average_word_repetitions);
      const heat = wa.alloc(u8, estimated_arena_size) catch |err| {
        return fail(err, "preallocating memory for words", .{});
      };
      wa.free(heat);
    }
    std.log.debug("word arena capacity: {}", .{ word_arena.queryCapacity() });

    var any_file_reader = file.reader().any();
    parseFileToWordMap(
      &word_arena, &scratch_arena, &word_map, &any_file_reader) catch |err| {
        return fail(err, "trying to parse `{s}`", .{ file_name });
      };
  }

  try printWordMap(&scratch_arena, &word_map);
}

pub fn main() !void
{
  entry() catch |err| {
    if (err == error.Handled) {
      STDERR.print("zw: {s}", .{ ERROR_LOG.getLogBuffer() }) catch unreachable;
      std.process.exit(1);
    }
    unreachable; // unhandled error :(
  };
  std.process.cleanExit();
}

const std = @import("std");
const builtin = @import("builtin");
