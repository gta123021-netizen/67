use mlua::Lua;

fn main() {
    let lua = Lua::new();
    let mut bad = 0;
    for path in std::env::args().skip(1) {
        let src = std::fs::read_to_string(&path).expect("read");
        if let Err(e) = lua.load(&src).set_name(&path).into_function() {
            println!("{}: {}", path, e);
            bad += 1;
        }
    }
    if bad > 0 {
        std::process::exit(1);
    }
    println!("ok");
}
