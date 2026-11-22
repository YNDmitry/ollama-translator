use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use misaki_rs::{G2P, Language};
use ort::environment::Environment;
use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::Tensor;
use serde::Deserialize;
use tiny_http::{Header, Method, Response, Server};
use zip::ZipArchive;

const KOKORO_CONFIG_JSON: &str = include_str!("../assets/kokoro_config.json");
const SAMPLE_RATE: u32 = 24_000;
const STYLE_DIM: usize = 256;
const MAX_PHONEME_TOKENS: usize = 508;

extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

fn parent_is_alive(pid: i32) -> bool {
    if pid <= 0 {
        return true;
    }
    // kill(pid, 0) returns 0 if process exists and we can signal it,
    // or -1 with EPERM (1) if it exists under another user. ESRCH (3) means dead.
    let rc = unsafe { kill(pid, 0) };
    if rc == 0 {
        return true;
    }
    let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    err != 3 // ESRCH on macOS/POSIX
}

#[derive(Deserialize)]
struct KokoroConfig {
    vocab: HashMap<String, i64>,
}

#[derive(Deserialize)]
struct TTSRequest {
    text: String,
    #[serde(default = "default_voice")]
    voice: String,
    #[serde(default = "default_speed")]
    speed: f32,
}

fn default_voice() -> String {
    "af_heart".to_string()
}

fn default_speed() -> f32 {
    0.95
}

struct VoiceBank {
    /// voice_name -> flat f32 buffer of shape [num_frames, STYLE_DIM]
    voices: HashMap<String, Vec<f32>>,
}

impl VoiceBank {
    fn load_npz(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|e| format!("Failed to open {}: {e}", path.display()))?;
        let mut archive = ZipArchive::new(file).map_err(|e| format!("Invalid NPZ archive: {e}"))?;
        let mut voices = HashMap::new();

        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).map_err(|e| format!("NPZ entry error: {e}"))?;
            let raw_name = entry.name().to_string();
            let voice_name = raw_name.strip_suffix(".npy").unwrap_or(&raw_name).to_string();

            let mut buf = Vec::new();
            entry
                .read_to_end(&mut buf)
                .map_err(|e| format!("Failed reading {raw_name}: {e}"))?;

            let floats = parse_npy_f32(&buf).map_err(|e| format!("Failed parsing {raw_name}: {e}"))?;
            if floats.len() >= STYLE_DIM {
                voices.insert(voice_name, floats);
            }
        }

        if voices.is_empty() {
            return Err("No valid voices found in voices-v1.0.bin".to_string());
        }
        Ok(Self { voices })
    }

    fn style_vector(&self, voice: &str, token_count: usize) -> Result<Vec<f32>, String> {
        let data = self
            .voices
            .get(voice)
            .or_else(|| self.voices.get("af_heart"))
            .or_else(|| self.voices.values().next())
            .ok_or_else(|| format!("Voice '{voice}' not found"))?;

        let num_frames = data.len() / STYLE_DIM;
        if num_frames == 0 {
            return Err(format!("Corrupt voice data for '{voice}'"));
        }
        let frame_idx = token_count.min(num_frames - 1);
        let start = frame_idx * STYLE_DIM;
        Ok(data[start..start + STYLE_DIM].to_vec())
    }
}

/// Parses a standard little-endian float32 NumPy `.npy` file (v1.0 / v2.0 / v3.0).
fn parse_npy_f32(bytes: &[u8]) -> Result<Vec<f32>, String> {
    if bytes.len() < 10 || &bytes[0..6] != b"\x93NUMPY" {
        return Err("Missing NPY magic header".to_string());
    }
    let major = bytes[6];
    let (header_len, data_offset) = match major {
        1 => {
            let len = u16::from_le_bytes([bytes[8], bytes[9]]) as usize;
            (len, 10 + len)
        }
        2 | 3 => {
            if bytes.len() < 12 {
                return Err("Truncated NPY v2 header".to_string());
            }
            let len = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize;
            (len, 12 + len)
        }
        other => return Err(format!("Unsupported NPY version {other}")),
    };

    if bytes.len() < data_offset {
        return Err(format!(
            "Truncated NPY payload (header_len={header_len}, total={})",
            bytes.len()
        ));
    }

    let payload = &bytes[data_offset..];
    if payload.len() % 4 != 0 {
        return Err("NPY f32 payload length is not a multiple of 4".to_string());
    }

    let mut out = Vec::with_capacity(payload.len() / 4);
    for chunk in payload.chunks_exact(4) {
        out.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }
    Ok(out)
}

fn load_vocab() -> HashMap<char, i64> {
    let parsed: KokoroConfig =
        serde_json::from_str(KOKORO_CONFIG_JSON).expect("Embedded kokoro_config.json must be valid JSON");
    let mut map = HashMap::with_capacity(parsed.vocab.len());
    for (k, v) in parsed.vocab {
        if let Some(ch) = k.chars().next() {
            if k.chars().count() == 1 {
                map.insert(ch, v);
            }
        }
    }
    map
}

fn tokenize_phonemes(phonemes: &str, vocab: &HashMap<char, i64>) -> Vec<i64> {
    phonemes
        .chars()
        .filter_map(|c| vocab.get(&c).copied())
        .collect()
}

/// Splits long input text into natural sentence/clause chunks so every chunk stays well within Kokoro's 510-token limit.
fn split_text_chunks(text: &str) -> Vec<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let mut chunks = Vec::new();
    let mut current = String::new();
    let max_chars = 260;

    for ch in trimmed.chars() {
        current.push(ch);
        let is_sentence_end = matches!(ch, '.' | '!' | '?' | '\n');
        let is_soft_break = matches!(ch, ';' | ':' | ',' | '—') && current.len() >= 140;

        if is_sentence_end || is_soft_break || (ch.is_whitespace() && current.len() >= max_chars) {
            let piece = current.trim().to_string();
            if !piece.is_empty() {
                chunks.push(piece);
            }
            current.clear();
        }
    }

    let tail = current.trim().to_string();
    if !tail.is_empty() {
        chunks.push(tail);
    }
    chunks
}

/// Encodes mono 24 kHz f32 audio samples into a standard 16-bit PCM WAV byte buffer.
fn encode_wav_pcm16(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let riff_size = 36 + data_bytes;
    let byte_rate = sample_rate * 2;
    let block_align: u16 = 2;
    let bits_per_sample: u16 = 16;

    let mut wav = Vec::with_capacity(44 + data_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // Mono
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());

    for &s in samples {
        let clamped = s.clamp(-1.0, 1.0);
        let pcm = (clamped * 32767.0).round() as i16;
        wav.extend_from_slice(&pcm.to_le_bytes());
    }
    wav
}

struct KokoroEngine {
    _env: Environment,
    session: Session,
    token_input_name: String,
    voices: VoiceBank,
    vocab: HashMap<char, i64>,
    g2p_us: G2P,
    g2p_gb: G2P,
}

impl KokoroEngine {
    fn load(model_dir: &Path) -> Result<Self, String> {
        let model_path = {
            let full = model_dir.join("kokoro-v1.0.onnx");
            let int8 = model_dir.join("kokoro-v1.0.int8.onnx");
            if full.exists() {
                full
            } else if int8.exists() {
                int8
            } else {
                return Err(format!(
                    "No Kokoro ONNX model found in {} (expected kokoro-v1.0.onnx)",
                    model_dir.display()
                ));
            }
        };
        let voices_path = model_dir.join("voices-v1.0.bin");
        if !voices_path.exists() {
            return Err(format!("Voices file not found: {}", voices_path.display()));
        }

        let threads = std::thread::available_parallelism()
            .map(|n| n.get().clamp(2, 6))
            .unwrap_or(4);

        let env = ort::init()
            .with_name("kokoro_tts")
            .build()
            .map_err(|e| format!("ORT env init error: {e}"))?;

        let session = Session::builder(&env)
            .map_err(|e| format!("ORT session builder error: {e}"))?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| format!("ORT optimization level error: {e}"))?
            .with_intra_threads(threads)
            .map_err(|e| format!("ORT threads error: {e}"))?
            .commit_from_file(&model_path)
            .map_err(|e| format!("Failed to load ONNX model {}: {e}", model_path.display()))?;

        // Detect whether this ONNX export calls the token tensor "tokens" or "input_ids"
        let token_input_name = session
            .inputs()
            .iter()
            .find(|inp| inp.name() == "tokens" || inp.name() == "input_ids")
            .map(|inp| inp.name().to_string())
            .unwrap_or_else(|| "tokens".to_string());

        let voices = VoiceBank::load_npz(&voices_path)?;
        let vocab = load_vocab();
        let g2p_us = G2P::new(Language::EnglishUS);
        let g2p_gb = G2P::new(Language::EnglishGB);

        Ok(Self {
            _env: env,
            session,
            token_input_name,
            voices,
            vocab,
            g2p_us,
            g2p_gb,
        })
    }

    fn synthesize_wav(&mut self, text: &str, voice: &str, speed: f32) -> Result<Vec<u8>, String> {
        let speed = speed.clamp(0.5, 2.0);
        let is_british = voice.starts_with("bf_") || voice.starts_with("bm_");
        let chunks = split_text_chunks(text);
        if chunks.is_empty() {
            return Err("Empty text".to_string());
        }

        let mut all_samples: Vec<f32> = Vec::new();
        let pause_samples = (SAMPLE_RATE as f32 * 0.12) as usize;

        for (idx, chunk) in chunks.iter().enumerate() {
            let (phonemes, _) = (if is_british {
                self.g2p_gb.g2p(chunk)
            } else {
                self.g2p_us.g2p(chunk)
            })
            .map_err(|e| format!("G2P error: {e}"))?;

            let raw_ids = tokenize_phonemes(&phonemes, &self.vocab);
            if raw_ids.is_empty() {
                continue;
            }

            // Process in slices of at most MAX_PHONEME_TOKENS
            for slice in raw_ids.chunks(MAX_PHONEME_TOKENS) {
                let mut padded = Vec::with_capacity(slice.len() + 2);
                padded.push(0i64);
                padded.extend_from_slice(slice);
                padded.push(0i64);

                let style = self.voices.style_vector(voice, slice.len())?;

                let tokens_tensor = Tensor::from_array(([1usize, padded.len()], padded))
                    .map_err(|e| format!("Tokens tensor error: {e}"))?;
                let style_tensor = Tensor::from_array(([1usize, STYLE_DIM], style))
                    .map_err(|e| format!("Style tensor error: {e}"))?;
                let speed_tensor = Tensor::from_array(([1usize], vec![speed]))
                    .map_err(|e| format!("Speed tensor error: {e}"))?;

                let outputs = self
                    .session
                    .run(ort::inputs![
                        self.token_input_name.as_str() => tokens_tensor,
                        "style" => style_tensor,
                        "speed" => speed_tensor
                    ])
                    .map_err(|e| format!("ONNX inference failed: {e}"))?;

                let (_shape, audio_slice) = outputs[0]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| format!("Output tensor extract error: {e}"))?;

                all_samples.extend_from_slice(audio_slice);
            }

            if idx + 1 < chunks.len() && !all_samples.is_empty() {
                all_samples.resize(all_samples.len() + pause_samples, 0.0);
            }
        }

        if all_samples.is_empty() {
            return Err("No pronounceable phonemes produced".to_string());
        }

        Ok(encode_wav_pcm16(&all_samples, SAMPLE_RATE))
    }
}

struct CliArgs {
    host: String,
    port: u16,
    model_dir: PathBuf,
    idle_timeout: u64,
    parent_pid: i32,
    test_phrase: Option<String>,
    test_voice: String,
    out_wav: Option<PathBuf>,
}

fn default_model_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join("Library/Application Support/OllamaTranslator/kokoro")
}

fn parse_args() -> CliArgs {
    let mut args = CliArgs {
        host: "127.0.0.1".to_string(),
        port: 18421,
        model_dir: default_model_dir(),
        idle_timeout: 600,
        parent_pid: 0,
        test_phrase: None,
        test_voice: "af_heart".to_string(),
        out_wav: None,
    };

    let raw: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--host" if i + 1 < raw.len() => {
                args.host = raw[i + 1].clone();
                i += 2;
            }
            "--port" if i + 1 < raw.len() => {
                if let Ok(p) = raw[i + 1].parse() {
                    args.port = p;
                }
                i += 2;
            }
            "--model-dir" if i + 1 < raw.len() => {
                args.model_dir = PathBuf::from(&raw[i + 1]);
                i += 2;
            }
            "--idle-timeout" if i + 1 < raw.len() => {
                if let Ok(t) = raw[i + 1].parse() {
                    args.idle_timeout = t;
                }
                i += 2;
            }
            "--parent-pid" if i + 1 < raw.len() => {
                if let Ok(pid) = raw[i + 1].parse() {
                    args.parent_pid = pid;
                }
                i += 2;
            }
            "--test-phrase" if i + 1 < raw.len() => {
                args.test_phrase = Some(raw[i + 1].clone());
                i += 2;
            }
            "--voice" if i + 1 < raw.len() => {
                args.test_voice = raw[i + 1].clone();
                i += 2;
            }
            "--out" if i + 1 < raw.len() => {
                args.out_wav = Some(PathBuf::from(&raw[i + 1]));
                i += 2;
            }
            _ => i += 1,
        }
    }
    args
}

fn main() {
    let cli = parse_args();

    let engine = match KokoroEngine::load(&cli.model_dir) {
        Ok(e) => e,
        Err(err) => {
            eprintln!("kokoro-tts-rs startup error: {err}");
            std::process::exit(1);
        }
    };

    // Optional CLI self-test mode
    if let Some(phrase) = cli.test_phrase {
        let mut eng = engine;
        let t0 = Instant::now();
        match eng.synthesize_wav(&phrase, &cli.test_voice, 0.95) {
            Ok(wav) => {
                let ms = t0.elapsed().as_millis();
                if let Some(out) = cli.out_wav {
                    if let Err(e) = std::fs::write(&out, &wav) {
                        eprintln!("Failed writing {}: {e}", out.display());
                        std::process::exit(1);
                    }
                    println!("OK: wrote {} bytes to {} in {}ms", wav.len(), out.display(), ms);
                } else {
                    println!("OK: synthesized {} WAV bytes in {}ms", wav.len(), ms);
                }
            }
            Err(e) => {
                eprintln!("Synthesis failed: {e}");
                std::process::exit(1);
            }
        }
        return;
    }

    let addr = format!("{}:{}", cli.host, cli.port);
    let server = match Server::http(&addr) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("Failed to bind {addr}: {e}");
            std::process::exit(1);
        }
    };

    let engine = Arc::new(Mutex::new(engine));
    let start_instant = Instant::now();
    let last_activity_secs = Arc::new(AtomicU64::new(0));
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // Watchdog thread: exits cleanly on idle timeout or if parent app exits
    {
        let server_ref = Arc::clone(&server);
        let last_ref = Arc::clone(&last_activity_secs);
        let flag_ref = Arc::clone(&shutdown_flag);
        let idle_timeout = cli.idle_timeout;
        let parent_pid = cli.parent_pid;

        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(10));
            if flag_ref.load(Ordering::Relaxed) {
                return;
            }
            if !parent_is_alive(parent_pid) {
                flag_ref.store(true, Ordering::Relaxed);
                server_ref.unblock();
                return;
            }
            if idle_timeout > 0 {
                let now_sec = start_instant.elapsed().as_secs();
                let last = last_ref.load(Ordering::Relaxed);
                if now_sec.saturating_sub(last) >= idle_timeout {
                    flag_ref.store(true, Ordering::Relaxed);
                    server_ref.unblock();
                    return;
                }
            }
        });
    }

    for mut req in server.incoming_requests() {
        if shutdown_flag.load(Ordering::Relaxed) {
            break;
        }

        let method = req.method().clone();
        let url = req.url().to_string();

        if method == Method::Get && url == "/health" {
            let body = r#"{"status":"ok","engine":"rust"}"#;
            let header = Header::from_bytes("Content-Type", "application/json").unwrap();
            let _ = req.respond(Response::from_string(body).with_header(header));
            continue;
        }

        if method == Method::Post && url == "/shutdown" {
            let body = r#"{"status":"shutting_down"}"#;
            let header = Header::from_bytes("Content-Type", "application/json").unwrap();
            let _ = req.respond(Response::from_string(body).with_header(header));
            shutdown_flag.store(true, Ordering::Relaxed);
            break;
        }

        if method == Method::Post && url == "/tts" {
            last_activity_secs.store(start_instant.elapsed().as_secs(), Ordering::Relaxed);
            let mut body = String::new();
            if req.as_reader().read_to_string(&mut body).is_err() {
                let _ = req.respond(Response::from_string("Invalid body").with_status_code(400));
                continue;
            }

            let parsed: TTSRequest = match serde_json::from_str(&body) {
                Ok(p) => p,
                Err(e) => {
                    let _ = req.respond(Response::from_string(format!("Bad JSON: {e}")).with_status_code(400));
                    continue;
                }
            };

            let wav_result = {
                let mut guard = engine.lock().unwrap();
                guard.synthesize_wav(&parsed.text, &parsed.voice, parsed.speed)
            };
            last_activity_secs.store(start_instant.elapsed().as_secs(), Ordering::Relaxed);

            match wav_result {
                Ok(wav_bytes) => {
                    let header = Header::from_bytes("Content-Type", "audio/wav").unwrap();
                    let _ = req.respond(Response::from_data(wav_bytes).with_header(header));
                }
                Err(err) => {
                    let _ = req.respond(Response::from_string(err).with_status_code(500));
                }
            }
            continue;
        }

        let _ = req.respond(Response::from_string("Not Found").with_status_code(404));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vocab_loads_official_ipa_ids() {
        let vocab = load_vocab();
        assert_eq!(vocab.get(&'ˈ'), Some(&156));
        assert_eq!(vocab.get(&'ˌ'), Some(&157));
        assert_eq!(vocab.get(&'ː'), Some(&158));
        assert_eq!(vocab.get(&' '), Some(&16));
        assert!(vocab.len() > 100);
    }

    #[test]
    fn test_misaki_g2p_us_and_gb() {
        let us = G2P::new(Language::EnglishUS);
        let (ph_us, _) = us.g2p("Just a quick heads-up regarding the timeline.").unwrap();
        assert!(!ph_us.is_empty());

        let vocab = load_vocab();
        let ids = tokenize_phonemes(&ph_us, &vocab);
        assert!(ids.len() > 10);

        let gb = G2P::new(Language::EnglishGB);
        let (ph_gb, _) = gb.g2p("The schedule looks great on my end.").unwrap();
        assert!(!ph_gb.is_empty());
    }

    #[test]
    fn test_parse_npy_f32() {
        let header = b"{'descr': '<f4', 'fortran_order': False, 'shape': (2,), }  \n";
        let mut buf = Vec::new();
        buf.extend_from_slice(b"\x93NUMPY\x01\x00");
        buf.extend_from_slice(&(header.len() as u16).to_le_bytes());
        buf.extend_from_slice(header);
        buf.extend_from_slice(&1.5f32.to_le_bytes());
        buf.extend_from_slice(&(-0.25f32).to_le_bytes());

        let parsed = parse_npy_f32(&buf).unwrap();
        assert_eq!(parsed, vec![1.5f32, -0.25f32]);
    }

    #[test]
    fn test_encode_wav_pcm16_header() {
        let wav = encode_wav_pcm16(&[0.0, 0.5, -0.5, 1.0], 24_000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(wav.len(), 44 + 8);
    }

    #[test]
    fn test_split_text_chunks() {
        let chunks = split_text_chunks("First sentence. Second sentence! Third?");
        assert_eq!(chunks, vec!["First sentence.", "Second sentence!", "Third?"]);
    }
}
