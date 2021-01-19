type test = {
  repo_hash: string;
  commands: (string * string list) list;
}

let cmd_prompt = "### "

let is_prefix pfx s =
  String.length s >= String.length pfx &&
  String.sub s 0 (String.length pfx) = pfx

let rem_prefix pfx s =
  if not (is_prefix pfx s) then invalid_arg "rem_prefix"
  else String.sub s (String.length pfx) (String.length s - String.length pfx)

(* Test file format: {v
   REPO_HASH
   ### opam command
   output line 1
   output...
   ### <filename>
   contents...
   ### opam command
   output...
   ### ENV_VAR=x opam command
   output...
v}*)

let load_test f =
  let ic = open_in f in
  let repo_hash = try input_line ic with
    | End_of_file -> failwith "Malformed test file"
  in
  let commands =
    let rec aux commands =
      match input_line ic, commands with
      | s, commands when is_prefix cmd_prompt s ->
        aux ((rem_prefix cmd_prompt s, []) :: commands)
      | s, ((cmd,out) :: commands) ->
        aux ((cmd, s::out) :: commands)
      | exception End_of_file ->
        List.rev_map (fun (cmd, out) -> cmd, List.rev out) commands
      | _ -> failwith "Malformed test file"
    in
    aux []
  in
  close_in ic;
  { repo_hash; commands }

let cleanup_path path =
  try
    let prefix = Sys.getenv "OPAM_SWITCH_PREFIX" in
    OpamStd.Sys.split_path_variable path |>
    List.filter (fun p -> not (OpamStd.String.starts_with ~prefix p)) |>
    String.concat (String.make 1 OpamStd.Sys.path_sep)
  with Not_found -> path

let base_env =
  (try ["PATH", (Sys.getenv "PATH" |> cleanup_path)] with Not_found -> []) @
  (try ["HOME", Sys.getenv "HOME"] with Not_found -> []) @
  [
    "OPAMKEEPBUILDDIR", "1";
    "OPAMCOLOR", "never";
    "OPAMUTF8", "never";
    "OPAMNOENVNOTICE", "1";
    "OPAMNODEPEXTS", "1";
    "OPAMDOWNLOADJOBS", "1";
    "TMPDIR", Filename.get_temp_dir_name ();
  ]

(* See [opamprocess.safe_wait] *)
let rec waitpid pid =
  match Unix.waitpid [] pid with
  | exception Unix.Unix_error (Unix.EINTR,_,_) -> waitpid pid
  | exception Unix.Unix_error (Unix.ECHILD,_,_) -> 256
  | _, Unix.WSTOPPED _ -> waitpid pid
  | _, Unix.WEXITED n -> n
  | _, Unix.WSIGNALED _ -> failwith "signal"

let command ?(vars=[]) fmt =
  Printf.ksprintf (fun cmd ->
      let env =
        Array.of_list @@
        List.map (fun (var, value) -> Printf.sprintf "%s=%s" var value) @@
        (base_env @ vars)
      in
      let pid =
        Unix.create_process_env "sh" [| "sh"; "-c"; cmd |] env
          Unix.stdin Unix.stdout Unix.stdout
      in
      match waitpid pid with
      | 0 -> ()
      | ret -> Printf.ksprintf failwith "Error code %d: %s" ret cmd)
    fmt

let finally f x k = match f x with
  | r -> k (); r
  | exception e -> (try k () with _ -> ()); raise e

(* Borrowed from ocamltest_stdlib.ml *)
let rec mkdir_p dir =
  if Sys.file_exists dir then ()
  else let () = mkdir_p (Filename.dirname dir) in
       if not (Sys.file_exists dir) then
         Unix.mkdir dir 0o777
       else ()

let erase_file path =
  try Sys.remove path
  with Sys_error _ when Sys.win32 ->
    (* Deal with read-only attribute on Windows. Ignore any error from chmod
       so that the message always come from Sys.remove *)
    let () = try Unix.chmod path 0o666 with Sys_error _ -> () in
    Sys.remove path

let rm_rf path =
  let rec erase path =
    if Sys.is_directory path then begin
      Array.iter (fun entry -> erase (Filename.concat path entry))
                 (Sys.readdir path);
      Unix.rmdir path
    end else erase_file path
  in
    try if Sys.file_exists path then erase path
    with Sys_error err ->
      raise (Sys_error (Printf.sprintf "Failed to remove %S (%s)" path err))

let rec with_temp_dir f =
  let s =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "opam-reftest-%06x" (Random.int 0xffffff))
  in
  if Sys.file_exists s then
    with_temp_dir f
  else
  (mkdir_p s;
   finally f s @@ fun () -> rm_rf s)

let run_cmd ~opam ~dir ?(vars=[]) cmd =
  let complete_opam_cmd cmd args =
    Printf.sprintf
      "%s %s %s 2>&1 \
       | sed 's#%s#${BASEDIR}#g' \
       | sed 's#\\(/private\\)*%s/*opam-[0-9a-f]*-[0-9a-f]*/#${OPAMTMP}/#g'"
      opam cmd (String.concat " " args)
      dir
      (Filename.get_temp_dir_name ())
  in
  let env_vars = [
    "OPAM", opam;
    "OPAMROOT", Filename.concat dir "OPAM";
  ] @ vars
  in
  try
    match OpamStd.String.split_delim cmd ' ' with
    | "opam" :: cmd :: args ->
      command ~vars:env_vars "%s" (complete_opam_cmd cmd args)
    | lst ->
      let rec split var = function
        | v::r when OpamCompat.Char.uppercase_ascii v.[0] = v.[0] ->
          split (v::var) r
        | "opam" :: cmd :: args ->
          Some (List.rev var, cmd, args)
        | _ -> None
      in
      match split [] lst with
      | Some (vars, cmd, args) ->
        command ~vars:env_vars "%s %s" (String.concat " " vars)
          (complete_opam_cmd cmd args)
      | None ->
        command ~vars:env_vars "%s 2>&1" cmd
  with Failure _ -> ()

type command =
  | Run
  | File_contents of string

let parse_command cmd =
  if cmd.[0] = '<' && cmd.[String.length cmd - 1] = '>' then
    let f = String.sub cmd 1 (String.length cmd - 2) in
    File_contents f
  else
    Run

let write_file ~path ~contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let run_test t ?vars ~opam =
  let opamroot0 = Filename.concat (Sys.getcwd ()) ("root-"^t.repo_hash) in
  with_temp_dir @@ fun dir ->
  let opamroot = Filename.concat dir "OPAM" in
  if OpamStd.Sys.(os () <> Win32) then
    command "cp -a %s %s" opamroot0 opamroot
  else
    command "robocopy /e %s %s" opamroot0 opamroot;
  Sys.chdir dir;
  let dir = Sys.getcwd () in (* because it may need to be normalised on OSX *)
  command
    "%s var --quiet --root %s --global sys-ocaml-version=4.08.0 >/dev/null"
    opam opamroot;
  print_endline t.repo_hash;
  List.iter (fun (cmd, out) ->
      print_string cmd_prompt;
      print_endline cmd;
      match parse_command cmd with
      | File_contents path ->
        let contents = String.concat "\n" out ^ "\n" in
        write_file ~path ~contents;
        print_string contents
      | Run ->
        run_cmd ~opam ~dir ?vars cmd)
    t.commands

let () =
  Random.self_init ();
  match Array.to_list Sys.argv with
  | _ :: opam :: input :: env ->
    let opam = OpamFilename.(to_string (of_string opam)) in
    let vars =
      List.map (fun s -> match OpamStd.String.cut_at s '=' with
          | Some (var, value) -> var, value
          | None -> failwith "Bad 'var=value' argument")
        env
    in
    load_test input |> run_test ~opam ~vars
  | _ ->
    failwith "Expected arguments: opam.exe file.test opamroot [env-bindings]"
