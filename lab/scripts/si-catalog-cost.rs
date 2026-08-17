//! Measure what carried SI costs the hang catalog, for
//! [#2882](https://github.com/moq-dev/moq/issues/2882).
//!
//! Imports a TS file and records every catalog publish on all three tracks
//! (`catalog.json`, `catalog.json.z`, the MSF catalog), writing one JSONL record per publish so
//! the attribution can be done afterwards: which publishes were caused by an SI change, how large
//! each snapshot was, and how much of it is SI.
//!
//! Usage: si_catalog_cost <in.ts> [max_packets] > publishes.jsonl

use anyhow::Context;
use moq_mux::catalog::hang::Catalog;
use moq_mux::container::ts::Ext;

const TS: usize = 188;
const CHUNK: usize = TS * 700;

/// Drain one catalog track, recording the byte size of every snapshot it publishes.
///
/// `keep_payload` is set only for the plaintext track: the compressed and MSF tracks are the same
/// catalog in another encoding, so their sizes matter and their contents do not.
async fn drain(
	mut track: moq_net::track::Subscriber,
	keep_payload: bool,
	fed: std::sync::Arc<std::sync::atomic::AtomicUsize>,
) -> Vec<(usize, Option<String>, usize)> {
	let mut out = Vec::new();
	while let Ok(Some(mut group)) = track.next_group().await {
		let mut bytes = 0;
		let mut payload = None;
		while let Ok(Some(frame)) = group.read_frame().await {
			bytes += frame.payload.len();
			if keep_payload {
				payload = Some(String::from_utf8_lossy(&frame.payload).into_owned());
			}
		}
		// How far into the source this publish happened, to within one feed chunk. Enough to say
		// how long a burst of republishes lasted, which is the part a client feels.
		out.push((bytes, payload, fed.load(std::sync::atomic::Ordering::Relaxed)));
	}
	out
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
	let mut args = std::env::args().skip(1);
	let path = args.next().context("usage: si_catalog_cost <in.ts> [max_packets]")?;
	let max_packets: usize = args.next().map(|a| a.parse()).transpose()?.unwrap_or(usize::MAX);

	let data = std::fs::read(&path).with_context(|| format!("reading {path}"))?;
	let end = data.len().min(max_packets.saturating_mul(TS));

	let mut broadcast = moq_net::broadcast::Info::new().produce();
	let consumer = broadcast.consume();
	let catalog = moq_mux::catalog::Producer::with_catalog(&mut broadcast, Catalog::<Ext>::default())?;

	// Subscribe before importing: a track's cache is bounded, so a reader attached afterwards can
	// miss early publishes and understate the count.
	let plain = consumer.track(hang::Catalog::DEFAULT_NAME).context("hang track")?.subscribe(None);
	let compressed = consumer
		.track(hang::Catalog::COMPRESSED_NAME)
		.context("hangz track")?
		.subscribe(None);
	let msf = consumer.track(moq_msf::DEFAULT_NAME).context("msf track")?.subscribe(None);
	let (plain, compressed, msf) = tokio::join!(plain, compressed, msf);

	let fed = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
	let plain = tokio::spawn(drain(plain?, true, fed.clone()));
	let compressed = tokio::spawn(drain(compressed?, false, fed.clone()));
	let msf = tokio::spawn(drain(msf?, true, fed.clone()));

	let mut import = moq_mux::container::ts::Import::new(broadcast, catalog.reserve());
	let mut off = 0;
	while off < end {
		let stop = (off + CHUNK).min(end);
		import.decode(&data[off..stop])?;
		off = stop;
		fed.store(off, std::sync::atomic::Ordering::Relaxed);
		// The readers are tasks on this runtime; without a yield the whole file is imported before
		// any of them runs, and a bounded track cache would drop publishes we are here to count.
		tokio::task::yield_now().await;
	}
	import.finish()?;
	// Both hold a catalog producer handle, and the reader tasks only end when the last one goes.
	drop(import);
	drop(catalog);

	let (plain, compressed, msf) = tokio::join!(plain, compressed, msf);
	let (plain, compressed, msf) = (plain?, compressed?, msf?);

	for (i, (bytes, payload, at)) in plain.iter().enumerate() {
		let record = serde_json::json!({
			"seq": i,
			"plain": bytes,
			"at": at,
			"z": compressed.get(i).map(|(b, ..)| *b),
			"msf": msf.get(i).map(|(b, ..)| *b),
			"msf_payload": msf.get(i).and_then(|(_, p, _)| p.clone()),
			"catalog": payload.as_deref().and_then(|p| serde_json::from_str::<serde_json::Value>(p).ok()),
		});
		println!("{record}");
	}
	eprintln!(
		"si_catalog_cost: {} publishes, plain {} B, z {} B, msf {} B",
		plain.len(),
		plain.iter().map(|(b, ..)| b).sum::<usize>(),
		compressed.iter().map(|(b, ..)| b).sum::<usize>(),
		msf.iter().map(|(b, ..)| b).sum::<usize>(),
	);
	Ok(())
}
