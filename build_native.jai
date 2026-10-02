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
    if args.count != 3 {
        compiler_report("Usage: jai build_native.jai - <source directory> <output directory> <library name>");
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

    platform_directory: string;
    extra_args: [] string;
    #if OS == {
        case .WINDOWS;
            #assert CPU == .X64;
            platform_directory = "windows";
            extra_args = .["/MT", "/EHsc", "/std:c++17", "/D_CRT_SECURE_NO_WARNINGS"];
        case .LINUX;
            platform_directory = "linux";
            extra_args = .["-std=c++17", "-fPIC", "-msse4.1", "-pthread"];
        case .MACOS;
            platform_directory = "macos";
            #if CPU == .X64 extra_args = .["-std=c++17", "-fPIC", "-msse4.1"];
            else extra_args = .["-std=c++17", "-fPIC"];
        case;
            compiler_report("Unsupported platform.");
            return;
    }

    output := tprint("%/%/%", #filepath, output_directory, platform_directory);
    if !make_directory_if_it_does_not_exist(output, recursive = true) || !make_directory_if_it_does_not_exist(".build", recursive = true) {
        compiler_report("Could not create native build directories.");
        return;
    }
    
    set_working_directory(".build");
    if !build_cpp_static_lib(tprint("%/%", output, library_name), source, extra = extra_args) compiler_set_workspace_status(.FAILED);
}
