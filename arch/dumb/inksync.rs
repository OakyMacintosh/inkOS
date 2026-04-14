use std::env;
use std::fs::File;
use std::io::Read;
use std::fs::OpenOptions;
use std::io::Write;

// fn getDevice() -> std::io::Result<()>
fn getDevice() -> Result<(), Box<dyn std::error::Error>> {
    let DevPath = env::var("DEVICE");
    let mut dev = File::open("/dev/{}");
    let mut buffer = [0u8; 1024];
    let n = dev?.read(&mut buffer)?;

    match DevPath {
	Ok(val) => println!("Using {}", val),
	Err(e) => println!("Couldn't fetch the $DEVICE variable: {}", e),
    }
    
    //println!("Read {} bytes", n);
    Ok(())
}

fn main() {
    
    let mut args = env::args();
    let program = args.next().unwrap();
    println!("Program: {}", program);

    for arg in args {
	println!("Arg: {}", arg);
    }
}
