use mlua::{Lua, Result};

fn main() -> Result<()> {
    let lua = Lua::new();
    let g = lua.globals();
    g.set("readfile", lua.create_function(|_, p: String| Ok(std::fs::read_to_string(&p).map_err(mlua::Error::external)?))?)?;
    g.set("loadchunk", lua.create_function(|lua, (src, name): (String, String)| {
        let f = lua.load(&src).set_name(&name).into_function()?;
        Ok(f)
    })?)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    g.set("ARGS", args.clone())?;
    let src = std::fs::read_to_string(&args[0]).expect("read");
    match lua.load(&src).set_name(&args[0]).exec() {
        Ok(_) => Ok(()),
        Err(e) => {
            eprintln!("ERROR: {}", e);
            std::process::exit(1);
        }
    }
}
