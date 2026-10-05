#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Hash_Table";
#import "Process";
SOURCE_PATH :: "timelinefx";
OUTPUT_DIRECTORY :: "generated/TimelineFX";
LIB_BASE_NAME :: "timelinefx";

AT_COMPILE_TIME :: true; // Set false to build generate.exe

#if AT_COMPILE_TIME {
    #run,stallable {
        set_build_options_dc(.{do_output = false});
        set_working_directory(#filepath);
        tracy_path, valid := parse_tracy_path(get_build_options().compile_time_command_line);
        if !valid || !generate_timelinefx(tracy_path) compiler_set_workspace_status(.FAILED);
    }
} else {
    #import "System";
    #run {
        set_working_directory(#filepath);
        ensure_local_libclang_exists();
    }
    main :: () {
        set_working_directory(path_strip_filename(get_path_of_running_executable()));
        args := get_command_line_arguments();
        tracy_path, valid := parse_tracy_path(slice(args, 1, args.count));
        if !valid || !generate_timelinefx(tracy_path) exit(1);
    }
}

parse_tracy_path :: (args: [] string) -> (string, bool) {
    if args.count == 0 return "", true;
    if args.count != 2 || args[0] != "--tracy" || args[1].count == 0 {
        log_error("Usage: jai generate.jai - --tracy <Tracy public directory>");
        return "", false;
    }
    path, ok := get_absolute_path(args[1]);
    if !ok || !file_exists(tprint("%/tracy/Tracy.hpp", path)) {
        log_error("Missing Tracy headers: %/tracy/Tracy.hpp.", args[1]);
        return "", false;
    }
    return path, true;
}

generate_timelinefx :: (tracy_include_directory: string = "", check_types := false, build_native := true) -> bool {
    print("Building TimelineFX for %/%...\n", OS, CPU);
    if !file_exists(tprint("%/timelinefx.h", SOURCE_PATH)) {
        log_error("Missing TimelineFX source: %/timelinefx.h.", SOURCE_PATH);
        return false;
    }
    if build_native {
        command: [..] string;
        array_add(*command, "jai", "build_native.jai", "-", SOURCE_PATH, OUTPUT_DIRECTORY, LIB_BASE_NAME);
        if tracy_include_directory.count array_add(*command, tracy_include_directory);
        result := run_command(..command, capture_and_return_output = true, print_captured_output = true);
        array_free(command);
        if result.type != .EXITED || result.exit_code != 0 return false;
    }

    // Pull some stuff from internal header
    internal_header, internal_read := read_entire_file(tprint("%/timelinefx_internal.h", SOURCE_PATH));
    if !internal_read return false;
    invalid_value: string;
    for raw_line: split(internal_header, "\n") {
        line := trim(raw_line);
        if !begins_with(line, "#define tfxINVALID ") continue;
        assert(invalid_value.count == 0, "Multiple tfxINVALID definitions in timelinefx_internal.h.");
        advance(*line, "#define tfxINVALID ".count);
        invalid_value = trim(line);
    }
    if invalid_value.count == 0 {
        log_error("Missing tfxINVALID definition in %/timelinefx_internal.h.", SOURCE_PATH);
        return false;
    }

    platform_directory: string;
    extra_clang_arguments: [] string;
    #if OS == {
        case .WINDOWS;
            #assert CPU == .X64;
            platform_directory = "windows";
            extra_clang_arguments = .["-x", "c", "-std=c11", "-DWIN32"];
        case .LINUX;
            platform_directory = "linux";
            extra_clang_arguments = .["-x", "c", "-std=c11"];
        case .MACOS;
            platform_directory = "macos";
            extra_clang_arguments = .["-x", "c", "-std=c11"];
        case;
            log_error("Unsupported platform: %", OS);
            return false;
    }

    lib_directory := tprint("%/%", OUTPUT_DIRECTORY, platform_directory);
    options: Generate_Bindings_Options;
    options.generate_library_declarations = false;
    options.try_to_preserve_comments = true;
    options.mimic_spacing_flags = 0;
    options.header = sprint("%\nINVALID :: cast(Effect_ID) %;\n", PACKED_TYPES, invalid_value);
    options.alias_original_enum_names = true;
    options.visitor_with_data = visit_timelinefx_api;
    options.will_print_bindings = prepare_timelinefx_declarations;
    array_add(*options.library_search_paths, lib_directory);
    array_add(*options.libraries, .{filename = LIB_BASE_NAME, identifier = "timelinefx"});
    array_add(*options.strip_prefixes, "tfx_", "tfx", "TFX_");
    array_add(*options.source_files, tprint("%/timelinefx.h", SOURCE_PATH));
    array_add(*options.extra_clang_arguments, ..extra_clang_arguments);

    output_file := tprint("%/%.jai", lib_directory, platform_directory);
    options.generate_compile_time_struct_checks = check_types;
    print("Generating % (layout checks: %)...\n", output_file, check_types);
    bindings, generated := generate_bindings(options, log_results = true);
    if !generated return false;

    // Before:
    //     Context_Data :: struct {}
    //     Context :: *Context_Data;
    //     Library_Data :: struct {}
    //     Library :: *Library_Data;
    // After:
    //     Context_Data :: struct {}
    //     Context :: *Context_Data;
    //
    //     Library_Data :: struct {}
    //     Library :: *Library_Data;
    output: String_Builder;
    previous_blank := true;
    previous_comment := false;
    in_block_comment := false;
    previous_opaque: string;
    for line: split(builder_to_string(*bindings), "\n") {
        if line.count == 0 && previous_blank continue;
        
        top_level := line.count > 0 && !is_space(line[0]);
        declaration := top_level && contains(line, " :: ");
        paired_handle := previous_opaque.count > 0 && contains(line, tprint(" :: *%;", previous_opaque));
        
        comment := in_block_comment || begins_with(line, "//") || begins_with(line, "/*");
        if begins_with(line, "/*") in_block_comment = true;
        if in_block_comment && contains(line, "*/") in_block_comment = false;
        
        if !previous_blank && ((declaration && !previous_comment && !paired_handle) || (comment && !previous_comment)) append(*output, "\n");
        
        print_to_builder(*output, "%\n", line);
        previous_blank = line.count == 0;
        previous_comment = comment;
        previous_opaque = "";
        if top_level && contains(line, " :: struct {}") previous_opaque = slice(line, 0, find_index_from_left(line, " :: "));
    }

    if !write_entire_file(output_file, *output) return false;
    if !write_entire_file(tprint("%/module.jai", OUTPUT_DIRECTORY), MODULE_SOURCE) return false;
    if !copy_file(tprint("%/License.txt", SOURCE_PATH), tprint("%/License.txt", OUTPUT_DIRECTORY)) return false;
    
    print("Generated %.\n", OUTPUT_DIRECTORY);
    return true;
}

// Resolve struct/handle name collisions from the C typedefs. e.g:
//     typedef struct tfx_context_s *tfx_context;
// becomes:
//     Context_Data :: struct {}
//     Context :: *Context_Data;
//
// The value typedef keeps the base name when present, otherwise the handle keeps it
// Also place types before functions because it's nicer
prepare_timelinefx_declarations :: () {
    for alias: context.generator.global_scope.members {
        if alias.kind != .TYPEDEF continue;
        
        pointer := find_underlying_type(alias.type);
        if !pointer || !pointer.pointer_to continue;
        
        pointee := find_underlying_type(pointer.pointer_to);
        if !pointee || !pointee.type_of_struct continue;
        
        record := pointee.type_of_struct;
        if alias.output_name != record.output_name continue;
        
        has_value_alias := false;
        for candidate: context.generator.global_scope.members {
            if candidate.kind != .TYPEDEF continue;
            value := find_underlying_type(candidate.type);
            if value && value.type_of_struct == record {
                has_value_alias = true;
                break;
            }
        }
        
        if has_value_alias alias.output_name = sprint("%_Handle", alias.output_name);
        else record.output_name = sprint("%_Data", record.output_name);
    }

    // After naming: "tfx_EndTimelineFX uses tfxEffectID" --> "end uses Effect_ID"
    names: Table(string, string);
    defer table_reset(*names);
    table_add(*names, "tfxINVALID", "INVALID");
    for decl: context.generator.global_scope.members visit_declarations(collect_comment_names, *names, decl);
    for decl: context.generator.global_scope.members visit_declarations(rewrite_comment_names, *names, decl);

    // Emit types before functions
    declarations: [..] *Declaration;
    for context.generator.flattened_global_scope_members if it.kind != .FUNCTION array_add(*declarations, it);
    for context.generator.flattened_global_scope_members if it.kind == .FUNCTION array_add(*declarations, it);
    context.generator.flattened_global_scope_members = declarations;
}

// So that documentation stays consistent with the jai bindings, we collect all the C/C++ defs in a table
// so that we may process comments again after
//  tfxU32 --> u32
//  tfx_context --> Context
//  tfxEffectFace_up --> Effect_Face.UP
collect_comment_names :: (decl: *Declaration, parent: *Declaration, user_data: *void) -> Declaration_Visit_Result {
    if !begins_with(decl.name, "tfx") && !begins_with(decl.name, "TFX_") return .RECURSE;
    names := cast(*Table(string, string)) user_data;
    
    name := decl.output_name;
    if decl.kind == .TYPEDEF {
        alias := cast(*Typedef) decl;
        if alias.unwrap name = type_to_string(alias.type, null);
    } else if parent && parent.kind == .ENUM {
        name = sprint("%.%", parent.output_name, decl.output_name);
    } else if decl.decl_flags & .OMIT_FROM_OUTPUT && decl.kind != .STRUCT {
        return .RECURSE;
    }
    
    if name.count > 0 table_add(names, decl.name, name);
    return .RECURSE;
}

// Replace whole identifiers in comment text only:
// "tfx_stage," --> "Stage,"
// "tfx_stage_extra" stays unchanged
rewrite_comment_names :: (decl: *Declaration, parent: *Declaration, user_data: *void) -> Declaration_Visit_Result {
    if decl.comment.text.count == 0 return .RECURSE;
    names := cast(*Table(string, string)) user_data;
    
    comment := decl.comment.text;
    output: String_Builder;
    start := 0;
    for index: 0..comment.count {
        c := ifx index < comment.count then comment[index] else 0;
        if is_alnum(c) continue;
        if index > start {
            word := slice(comment, start, index - start);
            found, replacement := table_find(names, word);
            append(*output, ifx found then replacement else word);
        }
        if index < comment.count append(*output, c);
        start = index + 1;
    }
    decl.comment.text = builder_to_string(*output);
    return .RECURSE;
}

visit_timelinefx_api :: (decl: *Declaration, parent: *Declaration, user_data: *void) -> Declaration_Visit_Result {
    // //Position --> // Position
    // already-spaced comments keep their spacing
    if decl.comment.text.count > 0 {
        normalized: String_Builder;
        for line, index: split(decl.comment.text, "\n") {
            if index > 0 append(*normalized, "\n");
            marker := find_index_from_left(line, "//");
            if marker >= 0 && marker + 2 < line.count && !is_space(line[marker + 2]) && line[marker + 2] != #char "/" && line[marker + 2] != #char "-" {
                append(*normalized, slice(line, 0, marker + 2));
                append(*normalized, " ");
                append(*normalized, slice(line, marker + 2, line.count - marker - 2));
            } else append(*normalized, line);
        }
        decl.comment.text = builder_to_string(*normalized);
    }

    // Top-level names: tfx_stage and tfx_UpdateStage
    // member names such as position stay local
    if !parent {
        // __builtin_va_list --> omitted
        // only TimelineFX declarations are exported.
        if !begins_with(decl.name, "tfx") && !begins_with(decl.name, "TFX_VERSION_") {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }

        name := decl.name;
        if begins_with(name, "tfx_") advance(*name, 4); // tfx_stage --> stage
        else if begins_with(name, "tfx") advance(*name, 3); // tfxEffectID --> EffectID
        else if begins_with(name, "TFX_") advance(*name, 4); // TFX_VERSION_MAJOR --> VERSION_MAJOR

        if decl.kind == .TYPEDEF { // typedef tfxU32 tfxEffectID; --> Effect_ID :: u32;
            alias := cast(*Typedef) decl;
            if decl.name == "tfxEffectID" { // Preserve Effect_ID in signatures instead of unwrapping to u32
                alias.unwrap = false;
                decl.output_name = "Effect_ID";
                return .STOP;
            }

            if ends_with(name, "Flags") { // tfxRefreshShapeFlags --> tfx_refresh_shape_flag_bits --> Refresh_Shape_Flags
                enum_name := tprint("tfx_%_flag_bits", pretty_name(slice(name, 0, name.count - "Flags".count), false));
                for candidate: context.generator.global_scope.members {
                    if candidate.kind != .ENUM || candidate.name != enum_name continue;
                    change_type_to_enum(alias, cast(*Enum) candidate);
                    alias.unwrap = true;
                    alias.decl_flags |= .OMIT_FROM_OUTPUT;
                    return .STOP;
                }
            }

            underlying := find_underlying_type(alias.type);
            // tfxU32 --> u32; tfx_random_t --> Random
            // The redundant typedef declaration is omitted
            if underlying && (underlying.number_flags != 0 || underlying.type_of_struct || underlying.type_of_enum) {
                alias.unwrap = true;
                alias.decl_flags |= .OMIT_FROM_OUTPUT;
                return .STOP;
            }
        }

        if decl.kind == .FUNCTION { // tfx_EndTimelineFX --> end
            if ends_with(name, "TimelineFX") name.count -= "TimelineFX".count; // EndTimelineFX --> End. UpdateStage stays UpdateStage.
            decl.output_name = pretty_name(name, false);
        } else if decl.kind == .STRUCT { // tfx_gpu_image_data_s --> GPU_Image_Data
            if ends_with(name, "_s") name.count -= 2; // gpu_image_data_s --> gpu_image_data
            decl.output_name = pretty_name(name, true);

            if begins_with(name, "float32x") { // tfx_float32x3_s --> Math.Vector3; omit the native struct.
                decl.output_name = sprint("Math.Vector%", name[name.count - 1] - #char "0");
                decl.decl_flags |= .OMIT_FROM_OUTPUT;
                return .STOP;
            }

            if name == "float16x4" || name == "float16x2" || name == "float8x4" { // tfx_float16x2_s --> Vector2_U16 :: u32
                // Packed structs become scalar aliases
                // fields keep these alias names
                if name == "float16x2" decl.output_name = "Vector2_U16"; // 2 x 16 bits --> u32
                if name == "float16x4" decl.output_name = "Vector4_U16"; // 4 x 16 bits --> u64
                if name == "float8x4" decl.output_name = "Vector4_U8"; // 4 x 8 bits --> u32
                decl.decl_flags |= .OMIT_FROM_OUTPUT;
                return .STOP;
            }

        } else if decl.kind == .ENUM { // tfx_color_format --> Color_Format
            decl.output_name = pretty_name(name, true);
            if ends_with(name, "_flag_bits") { // tfx_refresh_flag_bits --> Refresh_Flags :: enum_flags u32
                en := cast(*Enum) decl;
                en.type = context.generator.type_def_u32;
                en.flags |= .IS_ENUM_FLAGS | .VALUES_IN_HEX;
                name.count -= "_flag_bits".count;
                decl.output_name = sprint("%_Flags", pretty_name(name, true));
            }
        } else if name == to_upper_copy(name) { // TFX_VERSION_MAJOR --> VERSION_MAJOR
            decl.output_name = name;
        } else { // tfx_allocate_callback --> Allocate_Callback; tfx_stage --> Stage
            if ends_with(name, "_t") name.count -= 2; // random_t --> random
            decl.output_name = pretty_name(name, true);

        }

    } else if parent.kind == .FUNCTION && decl.name == "allocation_callbacks" { // allocation_callbacks: *Allocation_Callbacks --> allocation_callbacks: *Allocation_Callbacks = null
        decl.expression = create_literal("null", decl.location);
    } else if parent.kind == .ENUM { // tfx_color_format_rgba8 --> Color_Format.RGBA8
        name := pretty_name(decl.output_name, false);
        // tfxEffect_global_life_index --> Effect_Graph_Index.LIFE
        if ends_with(parent.name, "_graph_index") {
            if ends_with(name, "_index") name.count -= "_index".count; // global_life_index --> global_life
            if begins_with(name, "global_") advance(*name, "global_".count); // global_life --> life
            if name == "graphs_max" name = "count"; // graphs_max_index --> COUNT
        }
        decl.output_name = to_upper_copy(name);
    }
    return .RECURSE;
}

MODULE_SOURCE :: #string END
#module_parameters(DEBUG := false);

#if OS == .WINDOWS {
    #load "windows/windows.jai";
} else #if OS == .LINUX {
    #load "linux/linux.jai";
} else #if OS == .MACOS {
    #load "macos/macos.jai";
} else {
    #assert false;
}

#scope_module
Math :: #import "Math"; // For Vector types
#if OS == .WINDOWS {
    #if DEBUG {
        timelinefx :: #library,no_dll "windows/timelinefx_debug";
    } else {
        timelinefx :: #library,no_dll "windows/timelinefx";
    }
    #library,system,link_always "libcpmt";
} else #if OS == .LINUX {
    #if DEBUG {
        timelinefx :: #library,no_dll "linux/timelinefx_debug";
    } else {
        timelinefx :: #library,no_dll "linux/timelinefx";
    }
    #library,system "stdc++";
    #library,system "pthread";
    #library,system "m";
} else #if OS == .MACOS {
    #if DEBUG {
        timelinefx :: #library,no_dll "macos/timelinefx_debug";
    } else {
        timelinefx :: #library,no_dll "macos/timelinefx";
    }
    #library,system "c++";
}
END

PACKED_TYPES :: #string END

Vector4_U16 :: u64;
Vector2_U16 :: u32;
Vector4_U8 :: u32;

END

// Both C snake_case and PascalCase names occur in the public header
// This just unifies them to snake_case
pretty_name :: (name: string, title_case: bool) -> string {
    builder: String_Builder;
    for c, index: name {
        upper := to_lower(c) != c;
        if upper && index > 0 && name[index - 1] != #char "_" {
            previous_lower := to_upper(name[index - 1]) != name[index - 1];
            next_lower := index + 1 < name.count && to_upper(name[index + 1]) != name[index + 1];
            if previous_lower || next_lower append(*builder, "_");
        }
        append(*builder, to_lower(c));
    }
    
    result := builder_to_string(*builder);
    
    if title_case {
        for word: split(result, "_") {
            if word.count == 0 continue;
            word[0] = to_upper(word[0]);
            if word == "Gpu" || word == "Id" || word == "Uv" || word == "Fx" to_upper_in_place(word);
        }
    }
    return result;
}

