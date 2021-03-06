(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Hack_parallel.Std

module SharedMemory = SharedMem


type t = {
  is_parallel: bool;
  workers: Worker.t list;
  number_of_workers: int;
  bucket_multiplier: int;
}


let default_temporary_dir =
  "/pyre"


let default_shm_dirs =
  [ "/dev/shm"; default_temporary_dir ]


let entry =
  Worker.register_entry_point ~restore:(fun _ -> ())


let gc_control =
  Gc.get ()


let map_reduce
    { workers; bucket_multiplier; number_of_workers; _ }
    ?bucket_size
    ~init
    ~map
    ~reduce
    work =
  let number_of_workers =
    match bucket_size with
    | Some exact_size when exact_size > 0 ->
        (List.length work / exact_size) + 1
    | _ ->
        let bucket_multiplier = Core.Int.min bucket_multiplier (1 + (List.length work / 400)) in
        number_of_workers * bucket_multiplier
  in
  MultiWorker.call (Some workers)
    ~job:map
    ~merge:reduce
    ~neutral:init
    ~next:(Bucket.make ~num_workers:number_of_workers work)


let iter scheduler ~f work =
  map_reduce
    scheduler
    ~init:()
    ~map:(fun _ work -> Core.List.iter ~f work)
    ~reduce:(fun _ _ -> ())
    work


let rec wait_until_ready handle =
  let { Worker.readys; _ } = Worker.select [handle] in
  match readys with
  | [] -> wait_until_ready handle
  | ready :: _ ->
      ready


let single_job { workers; _ } ~f work =
  match workers with
  | worker::_ ->
      Worker.call worker f work
      |> wait_until_ready
      |> Worker.get_result
  | [] -> failwith "This service contains no workers"


module Memory = struct
  type bytes = int

  type configuration = {
    heap_handle: SharedMemory.handle;
    minor_heap_size: bytes;
  }

  let configuration: configuration option ref = ref None

  let initial_heap_size = 4096 * 1024 * 1024 (* 4 GB *)

  let initialize () =
    match !configuration with
    | None ->
        let minor_heap_size = 4 * 1024 * 1024 in (* 4 MB *)
        let space_overhead = 50 in
        Gc.set {
          (Gc.get ()) with
          Gc.minor_heap_size;
          space_overhead;
        };
        let shared_mem_config =
          let open SharedMemory in
          {
            global_size = initial_heap_size;
            heap_size = initial_heap_size;
            dep_table_pow = 19;
            hash_table_pow = 21;
            shm_dirs = default_shm_dirs;
            shm_min_avail = 1024 * 1024 * 512; (* 512 MB *)
            log_level = 0;
          } in
        let heap_handle = SharedMemory.init shared_mem_config in
        configuration := Some { heap_handle; minor_heap_size };
        { heap_handle; minor_heap_size }
    | Some configuration ->
        configuration

  let get_heap_handle () =
    let { heap_handle; _ } = initialize () in
    heap_handle

  let heap_use_ratio () =
    Core.Float.of_int (SharedMem.heap_size ()) /.
    Core.Float.of_int initial_heap_size

  let slot_use_ratio () =
    let { SharedMem.used_slots; slots; _ } = SharedMem.hash_stats () in
    Core.Float.of_int used_slots /. Core.Float.of_int slots
end


let create
    ~configuration:{ Configuration.parallel; number_of_workers; _ }
    ?(bucket_multiplier = 10)
    () =
  let heap_handle = Memory.get_heap_handle () in
  let workers =
    Hack_parallel.Std.Worker.make
      ?call_wrapper:None
      ~saved_state:()
      ~entry
      ~nbr_procs:number_of_workers
      ~heap_handle
      ~gc_control
  in
  SharedMemory.connect heap_handle ~is_master:true;
  { workers; number_of_workers; bucket_multiplier; is_parallel = parallel }


let mock () =
  Memory.initialize () |> ignore;
  { workers = []; number_of_workers = 1; bucket_multiplier = 1; is_parallel = false }


let is_parallel { is_parallel; _ } = is_parallel


let with_parallel ~is_parallel service = { service with is_parallel }


let destroy _ = Worker.killall ()
