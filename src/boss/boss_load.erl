%%-------------------------------------------------------------------
%% @author
%%     ChicagoBoss Team and contributors, see AUTHORS file in root directory
%% @end
%% @copyright
%%     This file is part of ChicagoBoss project.
%%     See AUTHORS file in root directory
%%     for license information, see LICENSE file in root directory
%% @end
%% @doc
%%-------------------------------------------------------------------

-module(boss_load).
-export([
        incoming_mail_controller_module/1,
        load_all_modules/2,
        load_all_modules/3,
        load_all_modules_and_emit_app_file/2,
        load_libraries/1,
        load_services_websockets/1,
        load_mail_controllers/1,
        load_models/1,
        load_view_if_dev/4,
        load_view_lib_modules/1,
        load_web_controllers/1,
        module_is_loaded/1,
        reload_all/0
    ]).
-include("boss_web.hrl").
-ifdef(TEST).
-compile(export_all).
-endif.

-type module_types() :: [{'controller_modules' | 'lib_modules' |
                          'mail_modules' | 'model_modules' | 'test_modules' |
                          'view_lib_helper_modules' | 'view_lib_tags_modules' | 'view_modules'
                          | 'websocket_modules',maybe_improper_list()},...].


-type reload_error_status_values() :: 'badfile' | 'native_code' | 'nofile' | 'not_purged' | 'on_load' | 'sticky_directory'.
-type application() :: types:application().


-spec incoming_mail_controller_module(application()) -> atom().
-spec load_all_modules(application(), atom() | pid() | {atom(),atom()}) -> {'ok',module_types()}.
-spec load_all_modules(application(),atom() | pid() | {atom(),atom()},_) -> {'ok',module_types()}.
-spec load_all_modules_and_emit_app_file(atom(),string()) -> 'ok' | {'error',atom()}.
-spec load_libraries(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec load_mail_controllers(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec load_models(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec load_services_websockets(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec load_view_if_dev(application(), atom() | binary() | [atom() | [any()] | char()],_,_) -> any().
-spec load_view_lib_modules(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec load_web_controllers(application()) -> {'error',[any(),...]} | {'ok',[any()]}.
-spec module_is_loaded(atom()) -> boolean().
-spec reload_all() -> [{'error',reload_error_status_values()}|
               {'module', atom() | tuple()}].

-define(CUSTOM_TAGS_DIR_MODULE, '_view_lib_tags').

load_all_modules(Application, TranslatorSupPid) ->
    load_all_modules(Application, TranslatorSupPid, undefined).

load_all_modules(Application, TranslatorSupPid, OutDir) ->
    _ = lager:debug("Loading application ~p", [Application]),
    _ = boss_modtime_srv:start(),
    [{_, TranslatorPid, _, _}]    = supervisor:which_children(TranslatorSupPid),
    Ops = make_ops_list(TranslatorPid),
    AllModules = make_all_modules(Application, OutDir, Ops),
    {ok, AllModules}.

-type error(X)   :: {ok, X} | {error, string()}.
-type op_key()   :: test_modules|lib_modules|websocket_modules|mail_modules|controller_modules|
                    model_modules| view_lib_tags_modules|view_lib_helper_modules|view_modules.
-type op()       :: {op_key(), fun((atom(), string()) -> error(_))}.
-spec(make_ops_list(pid()) -> [op()]).
make_ops_list(TranslatorPid) ->
    [{test_modules,            fun load_test_modules/2           },
     {lib_modules,             fun load_libraries/2              },
     {websocket_modules,       fun load_services_websockets/2    },
     {mail_modules,            fun load_mail_controllers/2       },
     {controller_modules,      fun load_web_controllers/2        },
     {model_modules,           fun load_models/2                 },
     {view_lib_helper_modules, fun load_view_lib_modules/2       },
     {view_lib_tags_modules,   load_view_lib(_, _, TranslatorPid)},
     {view_modules,            load_views(_, _, TranslatorPid)   }
	].

-spec make_all_modules(atom(), string(), [op()]) -> [{atom(),_}].

make_all_modules(Application, OutDir, Ops) ->
    lists:map(fun({Key, Lambda}) ->
              case Lambda(Application, OutDir) of
              {ok, Modules} ->
                  {Key, Modules};
              {error, Message} ->
                  _ = lager:error("Load Module Error ~p : ~p", [Key, Message]),
                  {Key, []}
              end
              end, Ops).

load_test_modules(Application, OutDir) ->
    Result = load_dirs(boss_files_util:test_path(),
        "*.{ex,erl}",
          Application,
              OutDir,
              fun compile/2),
    Result.

load_all_modules_and_emit_app_file(AppName, OutDir) ->
    application:start(elixir),
    {ok, TranslatorSupPid}                  = boss_translator:start([{application, AppName}]),
    {ok, TimedModulePropList}                    = load_all_modules(AppName, TranslatorSupPid, OutDir),

    TimedFlatModules = lists:flatmap(fun({_, TimedL}) -> TimedL end, TimedModulePropList),

    ModulePropList = lists:map(
        fun({Group, L}) ->
            {Group, [M || {M, _} <-  L]}
        end,
        TimedModulePropList
    ),

    AllModules = [M || {M, _} <- TimedFlatModules],
%%    AllModules                              = lists:foldr(fun({_, Mods}, Acc) -> Mods ++ Acc end, [], ModulePropList),
    dump_compile_times(TimedFlatModules),
    DotAppSrc                               = boss_files:dot_app_src(AppName),
    {ok, [{application, AppName, AppData}]} = file:consult(DotAppSrc),
    AppData1                                = lists:keyreplace(modules, 1, AppData, {modules, AllModules}),
    DefaultEnv                              = proplists:get_value(env, AppData1, []),
    AppData2                                = lists:keyreplace(env, 1, AppData1, {env, ModulePropList ++ DefaultEnv}),
    IOList                                  = io_lib:format("~p.~n", [{application, AppName, AppData2}]),
    AppFile                                 = filename:join([OutDir, lists:concat([AppName, ".app"])]),
    file:write_file(AppFile, IOList).


dump_compile_times(TimedModules) ->
    ok = filelib:ensure_dir(".cb/"),
    FileName = filename:join(".cb", "modules"),
    ok = file:write_file(FileName, io_lib:format("~tp.~n", [TimedModules])).


make_computed_vsn({unknown, Val} ) ->Val;
make_computed_vsn(Cmd ) ->
    VsnString = os:cmd(Cmd),
    string:strip(VsnString, right, $\n).


reload_all() ->
    _ = lager:notice("Reload All"),
    Modules = [M || {M, F} <- code:all_loaded(), is_list(F), not code:is_sticky(M)],
    [begin
     code:purge(M),
     code:load_file(M)
     end || M <- Modules].

load_libraries(Application) ->
    load_libraries(Application, undefined).
load_libraries(Application, OutDir) ->
    load_dirs(boss_files_util:lib_path(), "*.{ex,erl}", Application, OutDir, fun compile/2).

load_services_websockets(Application) ->
    load_services_websockets(Application, boss_files_util:ebin_dir()).
load_services_websockets(Application, OutDir) ->
    load_dirs(boss_files_util:websocket_path(), "*.{ex,erl}", Application, OutDir, fun compile/2).

load_mail_controllers(Application) ->
    load_mail_controllers(Application, undefined).
load_mail_controllers(Application, OutDir) ->
    load_dirs(boss_files:mail_controller_path(), "*.{ex,erl}", Application, OutDir, fun compile/2).

load_web_controllers(Application) ->
    load_web_controllers(Application, undefined).
load_web_controllers(Application, OutDir) ->
    load_dirs(boss_files_util:web_controller_path(), "*.{ex,erl}", Application, OutDir, fun compile_controller/2).

load_view_lib_modules(Application) ->
    load_view_lib_modules(Application, undefined).
load_view_lib_modules(Application, OutDir) ->
    load_dirs(boss_files_util:view_helpers_path(), "*.{ex,erl}", Application, OutDir, fun compile/2).

load_models(Application) ->
    load_models(Application, undefined).
load_models(Application, OutDir) ->
     load_dirs(boss_files_util:model_path(), "*.erl", Application, OutDir, fun compile_model/2).


%%*.{ex,erl}
load_dirs(Dirs, Mask, Application, OutDir, Compiler) ->
    load_dirs(Dirs, Mask, Application, OutDir, Compiler, [], []).

load_dirs([], _, _, _, _, ModuleAcc, []) ->
    {ok, ModuleAcc};
load_dirs([], _, _, _, _, _, ErrorAcc) ->
    {error, ErrorAcc};
load_dirs([Dir | Dirs], Mask, Application, OutDir, Compiler, ModuleAcc, ErrorAcc) ->
    Files = filelib:wildcard(filename:join(Dir, "**/" ++ Mask)),
    {ModuleAcc2, ErrorAcc2} = lists:foldl(
        fun(File, {MAcc, EAcc}) ->
            load_file(File, Application, OutDir, Compiler, MAcc, EAcc)
        end,
        {ModuleAcc, ErrorAcc},
        Files
    ),
    load_dirs(Dirs, Mask, Application, OutDir, Compiler, ModuleAcc2, ErrorAcc2).

load_file(Filename, Application, OutDir, Compiler, Modules, Errors) ->
    Now = calendar:local_time(),
    CompileResult = maybe_compile(Filename, Application, OutDir, Compiler),
    case CompileResult of
        ok ->
            {Modules, Errors};
        {ok, Module} ->
            boss_modtime_srv:set({Module, Now}),
            {[{Module, Now} | Modules], Errors};
        {error, Error} ->
            _ = lager:error("Compile Error, ~p -> ~p", [Filename, Error]),
            {Modules, [Error | Errors]};
        {error, NewErrors, _NewWarnings} when is_list(NewErrors) ->
            _ = lager:error("Compile Error, ~p -> ~p", [Filename, NewErrors]),
            {Modules, NewErrors ++ Errors}
    end.

maybe_compile(File, Application, OutDir, Compiler) ->
    CompilerAdapter = boss_files:compiler_adapter_for_extension(filename:extension(File)),
    maybe_compile(File, Application, OutDir, Compiler, CompilerAdapter).

maybe_compile(_File, _Application, _OutDir, _Compiler, undefined) -> ok;
maybe_compile(File, Application, OutDir, Compiler, CompilerAdapter) ->
    Module  = list_to_atom(CompilerAdapter:module_name_for_file(Application, File)),
    AbsPath = filename:absname(File),
    case OutDir of
    undefined ->
        case module_older_than(Module, [AbsPath]) of
        true ->
            Compiler(AbsPath, OutDir);
        _ ->
            {ok, Module}
        end;
    _ ->
        Compiler(AbsPath, OutDir)
    end.

view_doc_root(ViewPath) ->
    lists:foldl(fun
            (LibPath, Best) when length(LibPath) > length(Best) ->
                case lists:prefix(LibPath, ViewPath) of
                    true ->
                        LibPath;
                    false ->
                        Best
                end;
            (_, Best) ->
                Best
        end, "",
        [boss_files_util:web_view_path(), boss_files_util:mail_view_path()]).

compile_view_dir_erlydtl(Application, LibPath, Module, OutDir, TranslatorPid) ->
    TagHelpers           = lists:map(fun erlang:list_to_atom/1, boss_files_util:view_tag_helper_list(Application)),
    FilterHelpers        = lists:map(fun erlang:list_to_atom/1, boss_files_util:view_filter_helper_list(Application)),
    ExtraTagHelpers      = boss_env:get_env(template_tag_modules, []),
    ExtraFilterHelpers   = boss_env:get_env(template_filter_modules, []),

    _ = lager:debug("Compile Modules ~p  ~p", [LibPath, Module]),
    Res = erlydtl:compile_dir(LibPath, Module,
                            [{doc_root, view_doc_root(LibPath)}, {compiler_options, []}, {out_dir, OutDir},
                             {custom_tags_modules, TagHelpers ++ ExtraTagHelpers ++ [boss_erlydtl_tags]},
                             {custom_filters_modules, FilterHelpers ++ ExtraFilterHelpers},
                             {blocktrans_fun,
                              fun(BlockString, Locale) ->
                                      case boss_translator:lookup(TranslatorPid, BlockString, Locale) of
                                          undefined -> default;
                                          Body -> list_to_binary(Body)
                                      end
                              end}]),
    case Res of
        ok ->
            {ok, Module};
        Err -> Err
    end.

compile_view(Application, ViewPath, TemplateAdapter, OutDir, TranslatorPid) ->
    case file:read_file_info(ViewPath) of
        {ok, _} ->
            Module        = view_module(Application, ViewPath),
            HelperDirModule    = view_custom_tags_dir_module(Application),
            Locales        = boss_files:language_list(Application),
            DocRoot        = view_doc_root(ViewPath),
            TagHelpers        = lists:map(fun erlang:list_to_atom/1,
                        boss_files_util:view_tag_helper_list(Application)),
            FilterHelpers    = lists:map(fun erlang:list_to_atom/1,
                        boss_files_util:view_filter_helper_list(Application)),
            TemplateAdapter:compile_file(ViewPath, Module, [
                    {out_dir, OutDir},
                    {doc_root, DocRoot},
                    {translator_pid, TranslatorPid},
                    {helper_module, HelperDirModule},
                    {tag_helpers, TagHelpers},
                    {filter_helpers, FilterHelpers},
                    {locales, Locales}]);
        _ ->
            {error, not_found}
    end.

compile_model(ModulePath, OutDir) ->
    IncludeDirs = [boss_files_util:include_dir() | boss_env:get_env(boss, include_dirs, [])],
    boss_model_manager:compile(ModulePath, [{out_dir, OutDir}, {include_dirs, IncludeDirs},
             {compiler_options, compiler_options()}]).

compile_controller(ModulePath, OutDir) ->
    IncludeDirs = [boss_files_util:include_dir() | boss_env:get_env(boss, include_dirs, [])],
    Options = [{out_dir, OutDir}, {include_dirs, IncludeDirs}, {compiler_options, compiler_options()}],
    CompilerAdapter = boss_files:compiler_adapter_for_extension(filename:extension(ModulePath)),
    CompilerAdapter:compile_controller(ModulePath, Options).

compile(ModulePath, OutDir) ->
    IncludeDirs = [boss_files_util:include_dir() | boss_env:get_env(boss, include_dirs, [])],
    Options = [{out_dir, OutDir}, {include_dirs, IncludeDirs}, {compiler_options, compiler_options()}],
    CompilerAdapter = boss_files:compiler_adapter_for_extension(filename:extension(ModulePath)),
    CompilerAdapter:compile(ModulePath, Options).

compiler_options() ->
    lists:merge([{parse_transform, lager_transform}, return_errors],
        boss_env:get_env(boss, compiler_options, [])).

load_view_lib(Application, OutDir, TranslatorPid) ->
    Now = calendar:local_time(),
    {ok, HelperDirModule} = compile_view_dir_erlydtl(Application,
        boss_files_util:view_html_tags_path(), view_custom_tags_dir_module(Application),
        OutDir, TranslatorPid),
    boss_modtime_srv:set({HelperDirModule, Now}),
    {ok, [{HelperDirModule, Now}]}.

load_view_lib_if_old(Application, TranslatorPid) ->
    HelperDirModule = view_custom_tags_dir_module(Application),
    DirNeedsCompile = case module_is_loaded(HelperDirModule) of
        true ->
            module_older_than(HelperDirModule, lists:map(fun
                        ({File, _CheckSum}) -> File;
                        (File) -> File
                    end, [HelperDirModule:source_dir() | HelperDirModule:dependencies()]));
        false ->
            true
    end,
    case DirNeedsCompile of
        true ->
            load_view_lib(Application, undefined, TranslatorPid);
        false ->
            {ok, [HelperDirModule]}
    end.

load_views(Application, OutDir, TranslatorPid) ->
    ModuleList = lists:foldr(load_views_inner(Application, OutDir,
        TranslatorPid),
        [], boss_files:view_file_list()),
    {ok, ModuleList}.

load_views_inner(Application, OutDir, TranslatorPid) ->
    fun(File, Acc) ->
        TemplateAdapter = boss_files:template_adapter_for_extension(
            filename:extension(File)),
        Now = calendar:local_time(),
        ViewR = compile_view(Application, File, TemplateAdapter, OutDir, TranslatorPid),
        case ViewR of
            {ok, Module} ->
                [{Module, Now} | Acc];
            {error, Reason} ->
                _ = lager:error("Unable to compile ~p because of ~p",
                    [File, Reason]),
                Acc
        end
    end.

load_view_if_old(Application, ViewPath, Module, TemplateAdapter, TranslatorPid) ->
    case load_view_lib_if_old(Application, TranslatorPid) of
        {ok, _} ->
            NeedCompile = case module_is_loaded(Module) of
                true ->
                    Dependencies = lists:map(fun
                            ({File, _CheckSum}) -> File;
                            (File) -> File
                        end, [TemplateAdapter:source(Module) | TemplateAdapter:dependencies(Module)]),
                    TagHelpers = lists:map(fun erlang:list_to_atom/1, boss_files_util:view_tag_helper_list(Application)),
                    FilterHelpers = lists:map(fun erlang:list_to_atom/1, boss_files_util:view_filter_helper_list(Application)),
                    ExtraTagHelpers = boss_env:get_env(template_tag_modules, []),
                    ExtraFilterHelpers = boss_env:get_env(template_filter_modules, []),
                    module_older_than(Module,
                        Dependencies ++ TagHelpers ++ FilterHelpers ++ ExtraTagHelpers ++ ExtraFilterHelpers);
                false ->
                    true
            end,
            case NeedCompile of
                true ->
                    compile_view(Application, ViewPath, TemplateAdapter,
                        undefined, TranslatorPid);
                false ->
                    {ok, Module}
            end
    end.

load_view_if_dev(Application, ViewPath, ViewModules, TranslatorPid) ->
    Module          = view_module(Application, ViewPath),
    TemplateAdapter = boss_files:template_adapter_for_extension(filename:extension(ViewPath)),
    case boss_env:is_developing_app(Application) of
        true ->
            Now = calendar:local_time(),
            case load_view_if_old(Application, ViewPath, Module, TemplateAdapter, TranslatorPid) of
                {ok, Module} ->
                    boss_modtime_srv:set({Module, Now}),
                    {ok, Module, TemplateAdapter};
                Other ->
                    Other
            end;
        false ->
            case lists:member(atom_to_list(Module), ViewModules) of
                true ->
                    {ok, Module, TemplateAdapter};
                _ ->
                    {error, not_found}
            end
    end.

module_is_loaded(Module) ->
    case code:is_loaded(Module) of
        {file, _} ->
            true;
        _ ->
            false
    end.
-type maybe_list(X) :: X|list(X).
-spec(module_older_than(maybe_list(module()), maybe_list(string())) ->
              boolean()).
module_older_than(Module, Files) when is_atom(Module) ->
    case code:is_loaded(Module) of
        {file, _} ->
            module_older_than(module_compiled_date(Module), Files);
        _ ->
            case code:load_file(Module) of
                {module, _} ->
                    case code:is_loaded(Module) of
                        {file, _} ->
                            module_older_than(module_compiled_date(Module), Files)
                    end;
                {error, _} ->
                    true
            end
    end;
module_older_than(Module, Files) when is_list(Module) ->
    module_older_than(filelib:last_modified(Module), Files);
module_older_than(_Date, []) ->
    false;
module_older_than(CompileDate, [File|Rest]) when is_list(File) ->
    module_older_than(CompileDate, [filelib:last_modified(File)|Rest]);
module_older_than(CompileDate, [Module|Rest]) when is_atom(Module) ->
    {file, Loaded} = code:is_loaded(Module),
    module_older_than(CompileDate, [Loaded|Rest]);
module_older_than(CompileDate, [CompareDate|Rest]) ->
    (CompareDate > CompileDate) orelse module_older_than(CompileDate, Rest).

module_compiled_date(Module) when is_atom(Module) ->
    boss_modtime_srv:time(Module).

view_module(Application, RelativePath) ->
    Components   = tl(filename:split(RelativePath)),
    Lc           = string:to_lower(lists:concat([Application, "_", string:join(Components, "_")])),
    ModuleIOList = re:replace(Lc, "\\.", "_", [global]),
    list_to_atom(binary_to_list(iolist_to_binary(ModuleIOList))).

view_custom_tags_dir_module(Application) ->
    list_to_atom(lists:concat([Application, ?CUSTOM_TAGS_DIR_MODULE])).

incoming_mail_controller_module(Application) ->
    list_to_atom(lists:concat([Application, "_incoming_mail_controller"])).

