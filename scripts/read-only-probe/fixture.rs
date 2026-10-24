use std::{env, io::{self, BufRead, Write}, process::{Command, Stdio}, thread, time::Duration};
#[link(name="kernel32")]
extern "system" { fn GetCurrentProcess() -> *mut std::ffi::c_void; fn IsProcessInJob(p:*mut std::ffi::c_void,j:*mut std::ffi::c_void,r:*mut i32)->i32; fn GetHandleInformation(h:*mut std::ffi::c_void,f:*mut u32)->i32; }
fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(|s|s.as_str()).unwrap_or("echo") {
        "inspect" => {
            let mut in_job=0; unsafe { IsProcessInJob(GetCurrentProcess(), std::ptr::null_mut(), &mut in_job); }
            let mut flags=0; let handle=args[2].parse::<usize>().unwrap();
            let inherited=unsafe { GetHandleInformation(handle as *mut std::ffi::c_void,&mut flags) };
            println!("{}|{}|{}|{}|{}|{}", env::var("K32_VALUE").unwrap(), env::var("K32_PARENT_CANARY").is_err(), env::current_dir().unwrap().display(), in_job, inherited, args[3]);
        },
        "sleep" => thread::sleep(Duration::from_secs(120)),
        "crash" => std::process::exit(19),
        "oversize" => { io::stdout().write_all(&vec![b'x'; 1_048_577]).unwrap(); thread::sleep(Duration::from_secs(120)); },
        "invalid" => { io::stdout().write_all(&[0xff,b'\n']).unwrap(); },
        "flood" => { for _ in 0..1000 { println!("frame"); } thread::sleep(Duration::from_secs(120)); },
        "descendant" => { let c=Command::new(env::current_exe().unwrap()).arg("sleep").stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn().unwrap(); println!("{}",c.id()); io::stdout().flush().unwrap(); },
        _ => { for line in io::stdin().lock().lines() { println!("{}",line.unwrap()); io::stdout().flush().unwrap(); } }
    }
}
