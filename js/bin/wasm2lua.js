#!/usr/bin/env node
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const program = require("commander");
const fs = require("fs");
const fsExtra = require("fs-extra");
const path = require("path");
const __1 = require("..");
let infile, outfile;
let manifest = JSON.parse(fs.readFileSync(__dirname + "/../../package.json").toString());
program.version(manifest.version)
    .arguments("<in.wasm> <out.lua>")
    .option("--heapBase <__GLOBALS__[0]>", "Specify custom `heapBase` symbol name")
    .option("--freeName <free>", "Specify custom `free` symbol name")
    .option("--mallocName <malloc>", "Specify custom `malloc` symbol name")
    .option("--pureLua", "Compiles without using `ffi`")
    .option("-m, --minify", "Generates a minified Lua file")
    .option("-b, --bindings <bindings.idl>", "Generates Lua-WebIDL bindings from the specified file")
    .option("--libmode", "Adds a dummy main function to use this as a library (for WASI)")
    .option("--jmpstreamThreshold <n>", "Specify jump size of n(opcodes) as the threshold for enabling jmpstream")
    .action(function (inf, outf) {
    if ((typeof inf === "string") && (typeof outf === "string")) {
        if ((inf.trim() !== "") && (outf.trim() !== "")) {
            infile = path.resolve(inf.trim());
            outfile = path.resolve(outf.trim());
        }
    }
})
    .parse(process.argv);
if ((typeof infile === "undefined") || (typeof outfile === "undefined")) {
    program.outputHelp();
    process.exit(-1);
}
if (!fs.existsSync(infile)) {
    console.error(`Could not find input file ${infile}`);
}
fsExtra.ensureDirSync(path.dirname(outfile));
let conf = {};
if (program.bindings) {
    conf.webidl = {
        idlFilePath: program.bindings,
    };
}
if (program.bindings && program.mallocName) {
    conf.webidl.mallocName = program.mallocName;
}
if (program.bindings && program.freeName) {
    conf.webidl.freeName = program.freeName;
}
if (program.heapBase) {
    conf.heapBase = program.heapBase;
}
if (program.pureLua) {
    conf.pureLua = program.pureLua;
}
if (program.libmode) {
    conf.libMode = program.libmode;
}
if (program.jmpstreamThreshold) {
    conf.jmpStreamThreshold = parseInt(program.jmpstreamThreshold);
    if (!conf.jmpStreamThreshold || isNaN(conf.jmpStreamThreshold)) {
        conf.jmpStreamThreshold = null;
    }
}
let inst = new __1.wasm2lua(fs.readFileSync(infile), conf);
if (program.minify) {
    let src = inst.outBuf.join("");
    src = require("luamin").minify(src);
    fs.writeFileSync(outfile, src);
}
else {
    fs.writeFileSync(outfile, inst.outBuf.join(""));
}
//# sourceMappingURL=wasm2lua.js.map