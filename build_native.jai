#import "Basic";
#import "BuildCpp";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";

#run,stallable {
    set_build_options_dc(.{do_output = false});
    set_working_directory(#filepath);
    args := get_build_options().compile_time_command_line;
    if args.count != 3 && args.count != 4 {
        compiler_report("Usage: jai build_native.jai - <source directory> <output directory> <library name> [Tracy public directory]");
        return;
    }

    source_directory := args[0];
    output_directory := args[1];
    library_name := args[2];
    source, source_ok := get_absolute_path(tprint("%/timelinefx.cpp", source_directory));
    if !source_ok || !file_exists(source) {
        compiler_report(tprint("Missing TimelineFX source: %/timelinefx.cpp.", source_directory));
        return;
    }

    tracy_include_directory: string;
    if args.count == 4 {
        path, ok := get_absolute_path(args[3]);
        if args[3].count == 0 || !ok || !file_exists(tprint("%/tracy/Tracy.hpp", path)) {
            compiler_report(tprint("Missing Tracy headers: %/tracy/Tracy.hpp.", args[3]));
            return;
        }
        tracy_include_directory = path;
    }

    platform_directory: string;
    extra_args: [..] string;
    #if OS == {
        case .WINDOWS;
            #assert CPU == .X64;
            platform_directory = "windows";
            array_add(*extra_args, "/MT", "/EHsc", "/std:c++17", "/D_CRT_SECURE_NO_WARNINGS", "/Z7");
        case .LINUX;
            platform_directory = "linux";
            array_add(*extra_args, "-std=c++17", "-fPIC", "-msse4.1", "-pthread", "-g");
        case .MACOS;
            platform_directory = "macos";
            #if CPU == .X64 array_add(*extra_args, "-std=c++17", "-fPIC", "-msse4.1", "-g");
            else array_add(*extra_args, "-std=c++17", "-fPIC", "-g");
        case;
            compiler_report("Unsupported platform.");
            return;
    }

    if tracy_include_directory.count {
        #if OS == .WINDOWS array_add(*extra_args, "/DtfxTRACY", "/DTRACY_ENABLE", tprint("/I%", tracy_include_directory));
        else array_add(*extra_args, "-DtfxTRACY", "-DTRACY_ENABLE", tprint("-I%", tracy_include_directory));
    }

    output := tprint("%/%/%", #filepath, output_directory, platform_directory);
    if !make_directory_if_it_does_not_exist(output, recursive = true) || !make_directory_if_it_does_not_exist(".build", recursive = true) {
        compiler_report("Could not create native build directories.");
        return;
    }
    
    set_working_directory(".build");
    for debug: bool.[false, true] {
        // Keep /MT for runtime: the debug build changes optimization and symbols, not the CRT!
        #if OS == .WINDOWS if debug for *arg: extra_args if arg.* == "/Z7" arg.* = "/Ob0";
        name := ifx debug then tprint("%_debug", library_name) else library_name;
        if !build_cpp_static_lib(tprint("%/%", output, name), source, debug = debug, extra = extra_args) {
            compiler_set_workspace_status(.FAILED);
            return;
        }
    }
}
