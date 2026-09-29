use std::collections::HashMap;
use std::fs;
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use rbx_dom_weak::types::{Ref, Variant};
use rbx_dom_weak::{InstanceBuilder, WeakDom};

fn load(path: &str) -> WeakDom {
    let f = BufReader::new(fs::File::open(path).expect("open"));
    if path.ends_with(".rbxlx") || path.ends_with(".rbxmx") {
        rbx_xml::from_reader_default(f).expect("xml decode")
    } else {
        rbx_binary::from_reader(f).expect("binary decode")
    }
}

fn save(dom: &WeakDom, path: &str) {
    let refs: Vec<Ref> = dom.root().children().to_vec();
    let f = BufWriter::new(fs::File::create(path).expect("create"));
    if path.ends_with(".rbxlx") || path.ends_with(".rbxmx") {
        rbx_xml::to_writer_default(f, dom, &refs).expect("xml encode")
    } else {
        rbx_binary::to_writer(f, dom, &refs).expect("binary encode")
    }
}

fn is_script(class: &str) -> bool {
    class == "Script" || class == "LocalScript" || class == "ModuleScript"
}

fn ext(class: &str) -> &'static str {
    match class {
        "Script" => ".server.lua",
        "LocalScript" => ".client.lua",
        _ => ".lua",
    }
}

fn path_names(dom: &WeakDom, r: Ref) -> Vec<String> {
    let mut v = Vec::new();
    let mut cur = r;
    while let Some(inst) = dom.get_by_ref(cur) {
        if inst.parent().is_none() {
            break;
        }
        v.push(inst.name.clone());
        cur = inst.parent();
    }
    v.reverse();
    v
}

fn file_name(names: &[String], class: &str) -> String {
    let base: String = names
        .join("__")
        .chars()
        .map(|c| match c {
            '/' | ' ' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c => c,
        })
        .collect();
    base + ext(class)
}

fn get_source(inst: &rbx_dom_weak::Instance) -> Option<String> {
    match inst.properties.get(&"Source".into()) {
        Some(Variant::String(s)) => Some(s.clone()),
        Some(Variant::BinaryString(b)) => Some(String::from_utf8_lossy(b.as_ref()).into_owned()),
        Some(other) => panic!("unexpected source type {:?}", other.ty()),
        None => Some(String::new()),
    }
}

/// Every script in tree order, with a unique file name (duplicates get ~2, ~3...).
fn scripts(dom: &WeakDom) -> Vec<(Ref, String)> {
    let mut out = Vec::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut stack = vec![dom.root_ref()];
    while let Some(r) = stack.pop() {
        let inst = dom.get_by_ref(r).unwrap();
        if is_script(inst.class.as_str()) {
            let names = path_names(dom, r);
            let mut fname = file_name(&names, inst.class.as_str());
            let n = seen.entry(fname.clone()).or_insert(0);
            *n += 1;
            if *n > 1 {
                let e = ext(inst.class.as_str());
                fname = format!("{}~{}{}", &fname[..fname.len() - e.len()], n, e);
            }
            out.push((r, fname));
        }
        for c in inst.children().iter().rev() {
            stack.push(*c);
        }
    }
    out
}

fn fmt_variant(v: &Variant) -> String {
    match v {
        Variant::String(s) => {
            let s = s.replace('\n', "\\n");
            if s.len() > 120 { format!("{:?}...", &s[..s.char_indices().nth(120).map(|x| x.0).unwrap_or(s.len())]) } else { format!("{:?}", s) }
        }
        Variant::ContentId(c) => format!("{:?}", c.as_str()),
        Variant::Content(c) => format!("{:?}", c),
        Variant::Float32(f) => format!("{}", f),
        Variant::Float64(f) => format!("{}", f),
        Variant::Int32(i) => format!("{}", i),
        Variant::Int64(i) => format!("{}", i),
        Variant::Bool(b) => format!("{}", b),
        Variant::Enum(e) => format!("enum{}", e.to_u32()),
        Variant::Vector3(v) => format!("({:.3},{:.3},{:.3})", v.x, v.y, v.z),
        Variant::Vector2(v) => format!("({:.3},{:.3})", v.x, v.y),
        Variant::Color3(c) => format!("rgb({:.0},{:.0},{:.0})", c.r * 255.0, c.g * 255.0, c.b * 255.0),
        Variant::Color3uint8(c) => format!("rgb({},{},{})", c.r, c.g, c.b),
        Variant::CFrame(c) => format!("cf({:.2},{:.2},{:.2})", c.position.x, c.position.y, c.position.z),
        Variant::NumberRange(n) => format!("[{}..{}]", n.min, n.max),
        Variant::NumberSequence(n) => {
            let ks: Vec<String> = n.keypoints.iter().map(|k| format!("{:.2}:{:.2}", k.time, k.value)).collect();
            format!("ns[{}]", ks.join(" "))
        }
        Variant::ColorSequence(n) => {
            let ks: Vec<String> = n.keypoints.iter().map(|k| format!("{:.2}:rgb({:.0},{:.0},{:.0})", k.time, k.color.r * 255.0, k.color.g * 255.0, k.color.b * 255.0)).collect();
            format!("cs[{}]", ks.join(" "))
        }
        Variant::Attributes(a) => {
            let ks: Vec<String> = a.iter().map(|(k, v)| format!("{}={}", k, fmt_variant(v))).collect();
            format!("{{{}}}", ks.join(", "))
        }
        Variant::Tags(t) => format!("{:?}", t.iter().collect::<Vec<_>>()),
        Variant::Ref(r) => if r.is_none() { "nil".into() } else { "ref".into() },
        Variant::UDim2(u) => format!("ud2({},{},{},{})", u.x.scale, u.x.offset, u.y.scale, u.y.offset),
        Variant::BrickColor(b) => format!("bc{}", *b as u16),
        other => format!("<{:?}>", other.ty()),
    }
}

const SKIP_PROPS: &[&str] = &["Source", "LinkedSource", "ScriptGuid", "SourceAssetId", "UniqueId", "HistoryId", "Capabilities", "DefinesCapabilities", "Sandboxed", "PhysicsGrid", "SmoothGrid", "MaterialColors", "AttributesSerialize", "ModelMeshData", "PhysicalConfigData", "ChildData", "MeshData", "InitialSize", "PhysicsData"];

fn tree(dom: &WeakDom, out: &str, full: bool) {
    let mut w = BufWriter::new(fs::File::create(out).unwrap());
    let mut stack = vec![(dom.root_ref(), 0usize)];
    while let Some((r, depth)) = stack.pop() {
        let inst = dom.get_by_ref(r).unwrap();
        if depth > 0 {
            let mut line = format!("{}{} [{}]", "  ".repeat(depth - 1), inst.name, inst.class);
            if full {
                let mut props: Vec<_> = inst.properties.iter().filter(|(k, _)| !SKIP_PROPS.contains(&k.as_str())).collect();
                props.sort_by(|a, b| a.0.as_str().cmp(b.0.as_str()));
                for (k, v) in props {
                    if let Variant::BinaryString(_) | Variant::SharedString(_) = v { continue; }
                    line.push_str(&format!(" {}={}", k, fmt_variant(v)));
                }
            }
            writeln!(w, "{}", line).unwrap();
        }
        for c in inst.children().iter().rev() {
            stack.push((*c, depth + 1));
        }
    }
}

fn find_path(dom: &WeakDom, path: &str) -> Ref {
    let mut cur = dom.root_ref();
    for seg in path.split('/') {
        let inst = dom.get_by_ref(cur).unwrap();
        let next = inst.children().iter().find(|c| dom.get_by_ref(**c).unwrap().name == seg);
        cur = *next.unwrap_or_else(|| panic!("no child {} in path {}", seg, path));
    }
    cur
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args[1].as_str() {
        "convert" => {
            let dom = load(&args[2]);
            save(&dom, &args[3]);
        }
        "tree" => {
            let dom = load(&args[2]);
            tree(&dom, &args[3], args.get(4).map(|s| s == "full").unwrap_or(false));
        }
        "dump" => {
            let dom = load(&args[2]);
            let dir = Path::new(&args[3]);
            fs::create_dir_all(dir).unwrap();
            let mut manifest = BufWriter::new(fs::File::create(dir.join("_manifest.tsv")).unwrap());
            let list = scripts(&dom);
            for (r, fname) in &list {
                let inst = dom.get_by_ref(*r).unwrap();
                let src = get_source(inst).unwrap();
                fs::write(dir.join(fname), &src).unwrap();
                writeln!(manifest, "{}\t{}\t{}\t{}", fname, inst.class, path_names(&dom, *r).join("/"), src.len()).unwrap();
            }
            eprintln!("{} scripts", list.len());
        }
        "build" => {
            // build <in> <srcdir> <out> [adds.tsv]
            let mut dom = load(&args[2]);
            let dir = Path::new(&args[3]);
            let list = scripts(&dom);
            let mut updated = 0;
            for (r, fname) in &list {
                let p = dir.join(fname);
                if !p.exists() { continue; }
                let new = fs::read_to_string(&p).unwrap();
                let inst = dom.get_by_ref_mut(*r).unwrap();
                let old = get_source(inst).unwrap();
                if new != old {
                    inst.properties.insert("Source".into(), Variant::String(new));
                    println!("updated {}", fname);
                    updated += 1;
                }
            }
            if let Some(adds) = args.get(5) {
                // parentPath \t Name \t Class \t file
                for line in fs::read_to_string(adds).unwrap().lines() {
                    if line.trim().is_empty() || line.starts_with('#') { continue; }
                    let parts: Vec<&str> = line.split('\t').collect();
                    let parent = find_path(&dom, parts[0]);
                    let exists = dom.get_by_ref(parent).unwrap().children().iter().any(|c| dom.get_by_ref(*c).unwrap().name == parts[1]);
                    if exists { eprintln!("skip add {}/{} (exists)", parts[0], parts[1]); continue; }
                    let src = fs::read_to_string(dir.join(parts[3])).unwrap();
                    let mut b = InstanceBuilder::new(parts[2]).with_name(parts[1]).with_property("Source", Variant::String(src));
                    if parts[2] == "Script" || parts[2] == "LocalScript" {
                        b = b.with_property("Disabled", Variant::Bool(false));
                    }
                    dom.insert(parent, b);
                    println!("added {}/{} [{}]", parts[0], parts[1], parts[2]);
                    updated += 1;
                }
            }
            save(&dom, &args[4]);
            // verify
            let check = load(&args[4]);
            let a = scripts(&check);
            for (r, fname) in &a {
                let p = dir.join(fname);
                if p.exists() {
                    let src = get_source(check.get_by_ref(*r).unwrap()).unwrap();
                    assert_eq!(src, fs::read_to_string(&p).unwrap(), "{}", fname);
                }
            }
            println!("{} scripts, {} changes -> {}", a.len(), updated, args[4]);
        }
        "count" => {
            let dom = load(&args[2]);
            let mut n = 0;
            let mut classes: HashMap<String, usize> = HashMap::new();
            for d in dom.descendants() { n += 1; *classes.entry(d.class.to_string()).or_default() += 1; }
            let mut v: Vec<_> = classes.into_iter().collect();
            v.sort_by(|a, b| b.1.cmp(&a.1));
            println!("{} instances", n);
            for (c, k) in v.iter().take(60) { println!("{:6} {}", k, c); }
        }
        _ => panic!("unknown command"),
    }
}
