//! Assa o flavor (debug/release) no binário.
//!
//! O app namespaceia o socket por flavor (`status.sock` x `status-debug.sock`)
//! porque um Cockpit de dev e um instalado rodam lado a lado. A CLI é
//! materializada junto do app que a empacotou, então ela deve procurar PRIMEIRO
//! o socket do seu próprio flavor: sem isso, um comando externo disparado com a
//! CLI de dev acabava atendido pelo app instalado (foi o que aconteceu com o
//! `--focused`, que o app antigo não sabe resolver).
//!
//! Quem define é quem compila: `macos/build_cli.sh` e os CMakeLists passam
//! `COCKPIT_FLAVOR=debug` nos builds de desenvolvimento.

fn main() {
    println!("cargo:rerun-if-env-changed=COCKPIT_FLAVOR");
}
