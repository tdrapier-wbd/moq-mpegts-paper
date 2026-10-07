//! Subscribe to one track and write every object's payload to stdout, in arrival order.
//!
//! A per-object log (`group,object,bytes,arrival_us`) goes to `--log`. Exits once no
//! object has arrived for `--idle` seconds after the first, or when the track ends.
//!
//! ```text
//! # copied to rs/moq-tokio/examples/rawsub.rs in a moq-dev checkout:
//! cargo run -p moq-tokio --example rawsub -- --connect https://localhost:4481 --broadcast t11b --track ts --log objects.csv > rx.ts
//! ```

use std::io::Write;
use std::time::{Duration, Instant};

use anyhow::Context;

#[derive(usage::Cli, Clone)]
#[usage(unknown_flags = "error", args_override_self = false)]
#[usage(name = "rawsub")]
#[usage(settings)]
struct Config {
	#[usage(long)]
	broadcast: String,

	#[usage(flatten)]
	client: moq_tokio::connect::Config,

	#[usage(long)]
	track: String,

	#[usage(long)]
	log: std::path::PathBuf,

	#[usage(long, default = "5")]
	idle: u64,

	#[usage(flatten)]
	logging: moq_tokio::Log,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
	let config = Config::parse();
	config.logging.init()?;

	let url = config.client.url.clone().context("--connect is required")?;
	let client = config.client.init(Default::default())?;
	let origin = moq_tokio::origin::spawn();
	let reconnect = client.with_subscriber(origin.clone()).connect(url);

	let broadcast = origin
		.consume()
		.routed_broadcast(config.broadcast.as_str())
		.await
		.context("broadcast not found")?;
	let mut track = broadcast.track(&config.track)?.subscribe(None).await?;
	tracing::info!(track = %config.track, "subscribed");

	let mut log = std::fs::File::create(&config.log)?;
	writeln!(log, "group,object,bytes,arrival_us")?;
	let mut stdout = std::io::stdout().lock();
	let start = Instant::now();
	let idle = Duration::from_secs(config.idle);
	let (mut objects, mut bytes) = (0u64, 0u64);

	let result: anyhow::Result<()> = async {
		loop {
			let next = tokio::select! {
				res = track.recv_group() => res?,
				res = reconnect.closed() => { res?; None }
				_ = tokio::time::sleep(idle), if objects > 0 => None,
			};
			let Some(mut group) = next else { break };
			let sequence = group.sequence;
			let mut index = 0u64;
			loop {
				let frame = tokio::select! {
					res = group.read_frame() => res?,
					_ = tokio::time::sleep(idle), if objects > 0 => None,
				};
				let Some(frame) = frame else { break };
				stdout.write_all(&frame.payload)?;
				writeln!(log, "{sequence},{index},{},{}", frame.payload.len(), start.elapsed().as_micros())?;
				objects += 1;
				bytes += frame.payload.len() as u64;
				index += 1;
			}
		}
		Ok(())
	}
	.await;
	stdout.flush()?;
	eprintln!("received {objects} objects ({bytes} bytes)");
	result
}
