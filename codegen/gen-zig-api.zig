const std = @import("std");
const case = @import("case");
const cli = @import("cli");
const api_translator = @import("zigft/api-translator.zig");

const CliConfig = struct {
    outpath: []const u8,
};

var config = CliConfig{
    .outpath = undefined,
};

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

    const app = cli.App{
        .command = .{
            .name = "codegen",
            .options = try r.allocOptions(&.{
                cli.Option{
                    .long_name = "outpath",
                    .help = "Output path for generated bindings",
                    .required = true,
                    .value_ref = r.mkRef(&config.outpath),
                },
            }),
            .target = .{
                .action = .{
                    .exec = generate,
                },
            },
        },
    };

    return r.run(&app);
}

fn generate() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var generator: *api_translator.CodeGenerator(.{
        .include_paths = &[_][]const u8{
            "include/",
            "src/",
        },
        .header_paths = &[_][]const u8{
            "wildmidi_lib.h",
        },
        .zigft_path = "../../../codegen/zigft",
        .filter_fn = filter,
        .type_name_fn = getTypeName,
        .fn_name_fn = getFnName,
        .enum_name_fn = getEnumName,
        .error_name_fn = getErrorName,
        .const_name_fn = getConstName,
    }) = try .init(allocator);
    defer generator.deinit();

    // analyze the headers
    try generator.analyze();

    // save translated code to file
    var file = try std.fs.createFileAbsolute(config.outpath, .{});
    try generator.print(file.writer());

    file.close();
}

const camelize = api_translator.camelize;
const snakify = api_translator.snakify;

const prefixes = [_][]const u8{
    "WildMidi_",
    "WM_",
    "_WM_",
};

fn filter(name: []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return true;
        }
    }

    return false;
}

fn getFnName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return case.allocTo(allocator, .camel, name[prefix.len..]) catch @panic("OOM");
        }
    }

    return name;
}

fn getTypeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return camelize(allocator, name, prefix.len, true);
        }
    }

    return name;
}

fn getEnumName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return snakify(allocator, name, prefix.len);
        }
    }

    return name;
}

fn getConstName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return snakify(allocator, name, prefix.len);
        }
    }

    return name;
}

fn getErrorName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return getTypeName(allocator, name);
}
