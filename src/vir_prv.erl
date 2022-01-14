-module(vir_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, vir).
-define(DEPS, [app_discovery,compile]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},
            {module, ?MODULE},
            {bare, true},
            {deps, ?DEPS},
            {example, "rebar vir..."},
            {opts, [ {rerelease, $r, "rerelease", undefined, "Re-run the release and don't bump versions"},
                     {version, $v, "version", binary, "Specify  the version number to use"},
                     {label, $l, "label", binary, "Specify the build label to use"}
                   ]},
            {short_desc, short_desc()},
            {desc, desc()}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

desc() ->
    short_desc() ++ "\n"
    "\n"
    "This command will do tarred self-executing releases on a sensible operating system,"
    "and zips on weird ones"
    "\n".

short_desc() ->
    "Replacement for vir for our projects".


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
  State1 = update_materials(State),
  State2 = do_releases(State1),
  State3 = build_packages(State2),

  State4 = case is_rerelease(State3) of
             false -> tag_git(State3);
             true -> State3
           end,

  {ok, State4}.

update_materials(State) ->
  BranchName = strip(os_cmd("git rev-parse --abbrev-ref HEAD")),
  CommitHash = strip(os_cmd("git rev-parse --short HEAD")),
  MajorVer = read_version("major_ver"),
  MinorVer = read_version("minor_ver"),
  BuildNo = read_version("build_no"),
  BuildLabel = case override_label(State) of
                    false ->
                      case override_version(State) of
                        false ->
                          NewBuildNo = case is_rerelease(State) of
                                         false -> BuildNo + 1;
                                         true -> BuildNo
                                       end,
                          write_version("build_no", NewBuildNo),
                          write_version("major_ver", MajorVer),
                          write_version("minor_ver", MinorVer),
                          list_to_binary(io_lib:format("v~B.~B.~B-~s", [ MajorVer, MinorVer, NewBuildNo, binary_to_list(BranchName)]));
                        { true, Version } ->
                          list_to_binary(io_lib:format("v~s-~s", [ binary_to_list(Version), binary_to_list(BranchName)]))
                      end;
                    { true, Label } -> Label
               end,
  write_labels(BuildLabel, CommitHash),
  State1 = rebar_state:set(State, build_label, BuildLabel),
  State1.

do_releases(State) ->
  os_cmd("rm -rf _build/default/rel"),
  os_cmd("rebar3 clean"),
  os_cmd("rebar3 compile"),
  case rebar_state:get(State, relx, []) of
    [] ->
      io:format("No relx stuff configured - proceeding with default release strategy"),
      rebar_relx:do(release, State);
    _Releases ->
      io:format("Doing releases~n"),
      rebar_relx:do(release, rebar_state:command_parsed_args(State, {[{all, true}], []}))
  end,
  State.

build_packages(State) ->
  { ok, Releases } = file:list_dir("_build/default/rel"),
  BuildLabel = rebar_state:get(State, build_label),
  ok = filelib:ensure_dir("releases/foo.txt"),
  lists:foreach(fun (Release) ->
                    io:format("Packaging release ~p ~p~n", [ Release, BuildLabel ]),
                    Fullpath = filename:join("_build/default/rel/", Release),
                    os_cmd(string:join(["_build/default/plugins/rebar3_vir/priv/build_tar.sh", Fullpath, filename:absname("releases"), binary_to_list(BuildLabel)], " "))
                end, Releases),
  State.


tag_git(State) ->
  BuildLabel = rebar_state:get(State, build_label),
  os_cmd("git add deployment/build_no"),
  os_cmd("git add deployment/label"),
  os_cmd("git add apps/shared/include/version.hrl"),
  os_cmd("git commit -m 'Automated build number increase: " ++ binary_to_list(BuildLabel) ++ "'"),
  os_cmd("git tag " ++ binary_to_list(BuildLabel)),
  os_cmd("git push --tags"),
  os_cmd("git push origin `git rev-parse --abbrev-ref HEAD`"),
  State.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
  io_lib:format("~p", [Reason]).

read_version(File) ->
  case file:read_file(filename:join("deployment", File)) of
    { ok, Data } ->
      Clean = strip(Data),
      binary_to_integer(Clean);
    _ -> 0
  end.

write_version(File, Number) ->
  ok = filelib:ensure_dir("deployment/foo.txt"),
  ok = file:write_file(filename:join("deployment", File), << (integer_to_binary(Number))/binary, "\n" >>),
  ok.

strip(Data) ->
  re:replace(Data, "\\s+", "", [global,{return,binary}]).

write_labels(Label, CommitHash) ->
  case filelib:is_file("apps/shared/include/version.hrl") of
    true ->
      file:write_file("apps/shared/include/version.hrl",
                      <<"-define(VERSION, \"", Label/binary, "\").\r\n",
                        "-define(VERSION_COMMIT, \"", CommitHash/binary, "\").\r\n"
                      >>);
    _ ->
      ok
  end,
  file:write_file("deployment/label", << Label/binary, "\n">>),
  ok.

os_cmd(Cmd) ->
  Result = os:cmd(Cmd),
  rebar_api:debug("~p: ~p", [ Cmd, Result ]),
  Result.


is_rerelease(State) ->
  {Args, _} = rebar_state:command_parsed_args(State),
  case proplists:get_value(rerelease, Args) of
    undefined -> false;
    _ -> true
  end.

override_version(State) ->
  {Args, _} = rebar_state:command_parsed_args(State),
  case proplists:get_value(version, Args) of
    undefined -> false;
    Value -> { true, Value }
  end.

override_label(State) ->
  {Args, _} = rebar_state:command_parsed_args(State),
  case proplists:get_value(label, Args) of
    undefined -> false;
    Value -> { true, Value }
  end.
