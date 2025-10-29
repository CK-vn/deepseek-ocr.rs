#![allow(clippy::too_many_arguments)]

#[macro_use]
extern crate rocket;

mod bbox;

use std::{
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
    time::SystemTime,
};

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use candle_core::{DType, Tensor};
use clap::Parser;
use deepseek_ocr_assets as assets;
use deepseek_ocr_core::{
    inference::{
        build_prompt_tokens, compute_image_embeddings, normalize_text, prepare_vision_inputs,
    },
    model::{DeepseekOcrModel, GenerateOptions, OwnedVisionInput},
    runtime::{DeviceKind, Precision, default_dtype_for_device, prepare_device_and_dtype},
};
use image::DynamicImage;
use reqwest::blocking::Client;
use rocket::data::ToByteUnit;
use rocket::{
    Config, Either, State,
    futures::stream::Stream,
    http::Status,
    response::{
        Responder,
        status::Custom,
        stream::{Event, EventStream},
    },
    serde::json::Json,
    tokio::{self, sync::mpsc},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use thiserror::Error;
use tokenizers::Tokenizer;
use tokio_stream::wrappers::UnboundedReceiverStream;
use uuid::Uuid;

type SharedModel = Arc<Mutex<DeepseekOcrModel>>;
type BoxEventStream = EventStream<Pin<Box<dyn Stream<Item = Event> + Send>>>;

fn into_event_stream(rx: mpsc::UnboundedReceiver<Event>) -> BoxEventStream {
    let stream = UnboundedReceiverStream::new(rx);
    let boxed: Pin<Box<dyn Stream<Item = Event> + Send>> = Box::pin(stream);
    EventStream::from(boxed)
}

#[derive(Clone)]
struct StreamContext {
    sender: mpsc::UnboundedSender<Event>,
    kind: StreamKind,
}

impl StreamContext {
    fn send_error(&self, message: &str) {
        match &self.kind {
            StreamKind::Responses { .. } => {
                let _ = self.sender.send(Event::json(&json!({
                    "type": "response.error",
                    "error": { "message": message },
                })));
                let _ = self.sender.send(Event::data("[DONE]"));
            }
            StreamKind::Chat {
                completion_id,
                model,
                created,
            } => {
                let payload = json!({
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": serde_json::Value::Object(serde_json::Map::new()),
                        "finish_reason": "error",
                    }],
                    "error": { "message": message },
                });
                let _ = self.sender.send(Event::json(&payload));
                let _ = self.sender.send(Event::data("[DONE]"));
            }
        }
    }
}

#[derive(Clone)]
enum StreamKind {
    Responses {
        response_id: String,
        output_id: String,
        model: String,
        created: i64,
    },
    Chat {
        completion_id: String,
        model: String,
        created: i64,
    },
}

struct StreamController {
    inner: Arc<StreamControllerInner>,
}

struct StreamControllerInner {
    sender: mpsc::UnboundedSender<Event>,
    tokenizer: Arc<Tokenizer>,
    kind: StreamKind,
    runtime: Mutex<StreamRuntime>,
}

#[derive(Default)]
struct StreamRuntime {
    last_count: usize,
    role_sent: bool,
    finished: bool,
}

impl StreamControllerInner {
    fn send_initial(&self) {
        match &self.kind {
            StreamKind::Responses {
                response_id,
                model,
                created,
                ..
            } => {
                let _ = self.sender.send(Event::json(&json!({
                    "type": "response.created",
                    "response": {
                        "id": response_id,
                        "object": "response",
                        "created": created,
                        "model": model,
                    }
                })));
            }
            StreamKind::Chat {
                completion_id,
                model,
                created,
            } => {
                let payload = json!({
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": {
                            "role": "assistant",
                        },
                        "finish_reason": serde_json::Value::Null,
                    }],
                });
                let _ = self.sender.send(Event::json(&payload));
                if let Ok(mut state) = self.runtime.lock() {
                    state.role_sent = true;
                }
            }
        }
    }

    fn decode_tokens(&self, ids: &[i64]) -> Option<String> {
        let tokens: Vec<u32> = ids
            .iter()
            .filter_map(|&id| u32::try_from(id).ok())
            .collect();
        if tokens.is_empty() {
            return None;
        }
        self.tokenizer
            .decode(&tokens, true)
            .ok()
            .filter(|s| !s.is_empty())
    }

    fn emit_delta(&self, text: String, include_role: bool) {
        match &self.kind {
            StreamKind::Responses {
                response_id,
                output_id,
                model,
                created,
            } => {
                let payload = json!({
                    "type": "response.output_text.delta",
                    "response": {
                        "id": response_id,
                        "object": "response",
                        "created": created,
                        "model": model,
                    },
                    "output_id": output_id,
                    "output_index": 0,
                    "delta": text,
                });
                let _ = self.sender.send(Event::json(&payload));
            }
            StreamKind::Chat {
                completion_id,
                model,
                created,
            } => {
                let mut delta = json!({ "content": text });
                if include_role {
                    if let serde_json::Value::Object(obj) = &mut delta {
                        obj.insert("role".into(), serde_json::Value::String("assistant".into()));
                    }
                }
                let payload = json!({
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": delta,
                        "finish_reason": serde_json::Value::Null,
                    }],
                });
                let _ = self.sender.send(Event::json(&payload));
            }
        }
    }

    fn handle_progress(&self, count: usize, ids: &[i64]) {
        let (start, include_role) = {
            let mut state = self.runtime.lock().expect("stream state lock poisoned");
            if count <= state.last_count {
                return;
            }
            let start = state.last_count;
            state.last_count = count;
            let include_role = matches!(self.kind, StreamKind::Chat { .. }) && !state.role_sent;
            if include_role {
                state.role_sent = true;
            }
            (start, include_role)
        };

        if let Some(text) = self.decode_tokens(&ids[start..count]) {
            if !text.is_empty() {
                self.emit_delta(text, include_role);
            }
        }
    }

    fn flush_remaining(&self, ids: &[i64]) {
        let len = ids.len();
        if len == 0 {
            return;
        }
        let (start, include_role) = {
            let mut state = self.runtime.lock().expect("stream state lock poisoned");
            if len <= state.last_count {
                return;
            }
            let start = state.last_count;
            state.last_count = len;
            let include_role = matches!(self.kind, StreamKind::Chat { .. }) && !state.role_sent;
            if include_role {
                state.role_sent = true;
            }
            (start, include_role)
        };

        if let Some(text) = self.decode_tokens(&ids[start..len]) {
            if !text.is_empty() {
                self.emit_delta(text, include_role);
            }
        }
    }

    fn finalize(&self, normalized: &str, prompt_tokens: usize, completion_tokens: usize) {
        {
            let mut state = self.runtime.lock().expect("stream state lock poisoned");
            if state.finished {
                return;
            }
            state.finished = true;
        }

        match &self.kind {
            StreamKind::Responses {
                response_id,
                output_id,
                model,
                created,
            } => {
                let total_tokens = prompt_tokens + completion_tokens;
                let payload = json!({
                    "type": "response.completed",
                    "response": {
                        "id": response_id,
                        "object": "response",
                        "created": created,
                        "model": model,
                        "output": [{
                            "id": output_id,
                            "type": "message",
                            "role": "assistant",
                            "content": [{
                                "type": "output_text",
                                "text": normalized,
                            }],
                        }],
                        "usage": {
                            "input_tokens": prompt_tokens,
                            "output_tokens": completion_tokens,
                            "total_tokens": total_tokens,
                        },
                    }
                });
                let _ = self.sender.send(Event::json(&payload));
                let _ = self.sender.send(Event::data("[DONE]"));
            }
            StreamKind::Chat {
                completion_id,
                model,
                created,
            } => {
                let payload = json!({
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": serde_json::Value::Object(serde_json::Map::new()),
                        "finish_reason": "stop",
                    }],
                    "usage": {
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                        "total_tokens": prompt_tokens + completion_tokens,
                    }
                });
                let _ = self.sender.send(Event::json(&payload));
                let _ = self.sender.send(Event::data("[DONE]"));
            }
        }
    }
}

impl StreamController {
    fn new(tokenizer: Arc<Tokenizer>, context: StreamContext) -> Self {
        StreamController {
            inner: Arc::new(StreamControllerInner {
                sender: context.sender,
                tokenizer,
                kind: context.kind,
                runtime: Mutex::new(StreamRuntime::default()),
            }),
        }
    }

    fn send_initial(&self) {
        self.inner.send_initial();
    }

    fn flush_remaining(&self, tokens: &[i64]) {
        self.inner.flush_remaining(tokens);
    }

    fn finalize(&self, normalized: &str, prompt_tokens: usize, completion_tokens: usize) {
        self.inner
            .finalize(normalized, prompt_tokens, completion_tokens);
    }

    fn callback(&self) -> impl Fn(usize, &[i64]) + Send + Sync + 'static {
        let inner = Arc::clone(&self.inner);
        move |count: usize, ids: &[i64]| {
            inner.handle_progress(count, ids);
        }
    }
}

#[derive(Parser, Debug)]
#[command(author, version, about = "DeepSeek-OCR API Server", long_about = None)]
struct Args {
    /// Tokenizer path.
    #[arg(
        long,
        default_value = deepseek_ocr_assets::DEFAULT_TOKENIZER_PATH,
        value_name = "PATH"
    )]
    tokenizer: PathBuf,

    /// Optional weights override (defaults to DeepSeek-OCR/model-*.safetensors).
    #[arg(long, value_name = "PATH")]
    weights: Option<PathBuf>,

    /// Device backend (cpu/metal/cuda).
    #[arg(long, default_value = "cpu")]
    device: DeviceKind,

    /// Numeric precision override (cpu=f32 default, metal/cuda=f16).
    #[arg(long)]
    dtype: Option<Precision>,

    /// Global view resolution.
    #[arg(long, default_value_t = 1024)]
    base_size: u32,

    /// Local crop resolution.
    #[arg(long, default_value_t = 640)]
    image_size: u32,

    /// Enables dynamic crop mode.
    #[arg(long, default_value_t = true)]
    crop_mode: bool,

    /// Default max tokens budget per request.
    #[arg(long, default_value_t = 512)]
    max_new_tokens: usize,

    /// Host/IP for Rocket to bind to.
    #[arg(long, default_value = "0.0.0.0")]
    host: String,

    /// TCP port for Rocket.
    #[arg(long, default_value_t = 8000)]
    port: u16,

    /// Model identifier returned by /models.
    #[arg(long, default_value = "deepseek-ocr")]
    model_id: String,
}

struct AppState {
    model: SharedModel,
    tokenizer: Arc<Tokenizer>,
    base_size: u32,
    image_size: u32,
    crop_mode: bool,
    max_new_tokens: usize,
    model_id: String,
}

#[derive(Clone)]
struct GenerationInputs {
    model: SharedModel,
    tokenizer: Arc<Tokenizer>,
    base_size: u32,
    image_size: u32,
    crop_mode: bool,
}

impl GenerationInputs {
    fn from_state(state: &State<AppState>) -> Self {
        GenerationInputs {
            model: Arc::clone(&state.model),
            tokenizer: Arc::clone(&state.tokenizer),
            base_size: state.base_size,
            image_size: state.image_size,
            crop_mode: state.crop_mode,
        }
    }
}

#[rocket::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let weights_path = prepare_weights(args.weights.as_ref())?;
    let (device, maybe_dtype) = prepare_device_and_dtype(args.device, args.dtype)?;
    let dtype = maybe_dtype.unwrap_or_else(|| default_dtype_for_device(&device));
    let config_path = prepare_config()?;
    let model = DeepseekOcrModel::load(Some(&config_path), Some(&weights_path), device, dtype)
        .context("failed to load DeepSeek-OCR model")?;
    let tokenizer = prepare_tokenizer(&args.tokenizer)?;

    let state = AppState {
        model: Arc::new(Mutex::new(model)),
        tokenizer: Arc::new(tokenizer),
        base_size: args.base_size,
        image_size: args.image_size,
        crop_mode: args.crop_mode,
        max_new_tokens: args.max_new_tokens,
        model_id: args.model_id.clone(),
    };

    let figment = Config::figment()
        .merge(("port", args.port))
        .merge(("address", args.host.clone()))
        .merge((
            "limits",
            rocket::data::Limits::default()
                .limit("json", 50.megabytes())
                .limit("bytes", 50.megabytes()),
        ));

    println!(
        "Server ready on {}:{} ({})",
        args.host, args.port, state.model_id
    );

    rocket::custom(figment)
        .manage(state)
        .mount(
            "/v1",
            routes![
                health,
                list_models,
                responses_endpoint,
                chat_completions_endpoint
            ],
        )
        .launch()
        .await
        .map_err(|err| anyhow::anyhow!("rocket failed: {err}"))?;

    Ok(())
}

#[get("/health")]
fn health() -> &'static str {
    "ok"
}

#[get("/models")]
fn list_models(state: &State<AppState>) -> Json<ModelsResponse> {
    let now = current_timestamp();
    Json(ModelsResponse {
        object: "list".into(),
        data: vec![ModelInfo {
            id: state.model_id.clone(),
            object: "model".into(),
            created: now,
            owned_by: "deepseek".into(),
        }],
    })
}

#[post("/responses", format = "json", data = "<req>")]
async fn responses_endpoint(
    state: &State<AppState>,
    req: Json<ResponsesRequest>,
) -> Result<Either<Json<ResponsesResponse>, BoxEventStream>, ApiError> {
    ensure_model(&req.model, &state.model_id)?;
    let gen_inputs = GenerationInputs::from_state(state);
    let (prompt, images) = convert_messages(&req.input)?;
    let max_tokens = req
        .max_output_tokens
        .or(req.max_tokens)
        .unwrap_or(state.max_new_tokens);
    if req.stream.unwrap_or(false) {
        let stream_inputs = gen_inputs.clone();
        let created = current_timestamp();
        let response_id = format!("resp-{}", Uuid::new_v4());
        let output_id = format!("msg-{}", Uuid::new_v4());
        let (sender, rx) = mpsc::unbounded_channel();
        let stream = into_event_stream(rx);
        let context = StreamContext {
            sender,
            kind: StreamKind::Responses {
                response_id: response_id.clone(),
                output_id: output_id.clone(),
                model: state.model_id.clone(),
                created,
            },
        };
        let task_context = context.clone();
        tokio::spawn(async move {
            let _ = generate_async(
                stream_inputs,
                prompt,
                images,
                max_tokens,
                Some(task_context),
            )
            .await;
        });
        return Ok(Either::Right(stream));
    }
    let generation = generate_async(gen_inputs, prompt, images, max_tokens, None).await?;
    let created = current_timestamp();
    let response = ResponsesResponse {
        id: format!("resp-{}", Uuid::new_v4()),
        object: "response".into(),
        created,
        model: req.model.clone(),
        output: vec![ResponseOutput {
            id: format!("msg-{}", Uuid::new_v4()),
            r#type: "message".into(),
            role: "assistant".into(),
            content: vec![ResponseContent {
                r#type: "output_text".into(),
                text: generation.text.clone(),
                bounding_boxes: if generation.bounding_boxes.is_empty() {
                    None
                } else {
                    Some(generation.bounding_boxes.clone())
                },
                annotated_image: generation.annotated_image.clone(),
            }],
        }],
        usage: Usage {
            prompt_tokens: generation.prompt_tokens,
            completion_tokens: generation.response_tokens,
            total_tokens: generation.prompt_tokens + generation.response_tokens,
        },
    };
    Ok(Either::Left(Json(response)))
}

#[post("/chat/completions", format = "json", data = "<req>")]
async fn chat_completions_endpoint(
    state: &State<AppState>,
    req: Json<ChatCompletionRequest>,
) -> Result<Either<Json<ChatCompletionResponse>, BoxEventStream>, ApiError> {
    // Debug: log the incoming request
    eprintln!("DEBUG: Received chat completion request with {} messages", req.messages.len());
    for (idx, msg) in req.messages.iter().enumerate() {
        eprintln!("DEBUG: Message {}: role={}, content_type={}", 
                  idx, msg.role, 
                  match &msg.content {
                      MessageContent::Text(_) => "text",
                      MessageContent::Parts(parts) => &format!("parts({})", parts.len()),
                  });
    }
    
    ensure_model(&req.model, &state.model_id)?;
    let gen_inputs = GenerationInputs::from_state(state);
    let (prompt, images) = convert_messages(&req.messages)?;
    println!("{}", prompt);
    let max_tokens = req.max_tokens.unwrap_or(state.max_new_tokens);
    if req.stream.unwrap_or(false) {
        let stream_inputs = gen_inputs.clone();
        let created = current_timestamp();
        let completion_id = format!("chatcmpl-{}", Uuid::new_v4());
        let (sender, rx) = mpsc::unbounded_channel();
        let stream = into_event_stream(rx);
        let context = StreamContext {
            sender,
            kind: StreamKind::Chat {
                completion_id: completion_id.clone(),
                model: state.model_id.clone(),
                created,
            },
        };
        let task_context = context.clone();
        tokio::spawn(async move {
            let _ = generate_async(
                stream_inputs,
                prompt,
                images,
                max_tokens,
                Some(task_context),
            )
            .await;
        });
        return Ok(Either::Right(stream));
    }
    let generation = generate_async(gen_inputs, prompt, images, max_tokens, None).await?;
    let created = current_timestamp();
    let response = ChatCompletionResponse {
        id: format!("chatcmpl-{}", Uuid::new_v4()),
        object: "chat.completion".into(),
        created,
        model: req.model.clone(),
        choices: vec![ChatChoice {
            index: 0,
            message: ChatMessageResponse {
                role: "assistant".into(),
                content: generation.text.clone(),
                bounding_boxes: if generation.bounding_boxes.is_empty() {
                    None
                } else {
                    Some(generation.bounding_boxes.clone())
                },
                annotated_image: generation.annotated_image.clone(),
            },
            finish_reason: "stop".into(),
        }],
        usage: Usage {
            prompt_tokens: generation.prompt_tokens,
            completion_tokens: generation.response_tokens,
            total_tokens: generation.prompt_tokens + generation.response_tokens,
        },
    };
    Ok(Either::Left(Json(response)))
}

async fn generate_async(
    inputs: GenerationInputs,
    prompt: String,
    images: Vec<DynamicImage>,
    max_new_tokens: usize,
    stream: Option<StreamContext>,
) -> Result<GenerationResult, ApiError> {
    let stream_for_block = stream.clone();
    let join_result = rocket::tokio::task::spawn_blocking(move || {
        generate_blocking(
            &inputs.model,
            Arc::clone(&inputs.tokenizer),
            prompt,
            images,
            inputs.base_size,
            inputs.image_size,
            inputs.crop_mode,
            max_new_tokens,
            stream_for_block,
        )
    })
    .await;

    match join_result {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(err)) => {
            if let Some(ctx) = stream {
                ctx.send_error(&err.to_string());
            }
            Err(err)
        }
        Err(err) => {
            let api_err = ApiError::Internal(format!("generation task failed: {err}"));
            if let Some(ctx) = stream {
                ctx.send_error(&api_err.to_string());
            }
            Err(api_err)
        }
    }
}

fn generate_blocking(
    model: &SharedModel,
    tokenizer: Arc<Tokenizer>,
    prompt: String,
    images: Vec<DynamicImage>,
    base_size: u32,
    image_size: u32,
    crop_mode: bool,
    max_new_tokens: usize,
    stream: Option<StreamContext>,
) -> Result<GenerationResult, ApiError> {
    let guard = model
        .lock()
        .map_err(|_| ApiError::Internal("model lock poisoned".into()))?;
    let tokenizer_ref = tokenizer.as_ref();
    let stream_controller = stream.map(|ctx| StreamController::new(Arc::clone(&tokenizer), ctx));
    let owned_inputs = prepare_inputs(&*guard, &images, base_size, image_size, crop_mode)?;
    let embeddings = compute_image_embeddings(&*guard, &owned_inputs)
        .map_err(|err| ApiError::Internal(format!("image embedding failed: {err:#}")))?;
    let (input_ids_vec, mask_vec) = build_prompt_tokens(
        tokenizer_ref,
        &prompt,
        &embeddings,
        &owned_inputs,
        base_size,
        image_size,
        crop_mode,
    )
    .map_err(|err| ApiError::BadRequest(format!("prompt formatting failed: {err:#}")))?;

    let input_len = input_ids_vec.len();
    let token_device = guard.device();

    let input_ids = Tensor::from_vec(input_ids_vec.clone(), (1, input_len), token_device)
        .map_err(|err| ApiError::Internal(format!("input tensor failed: {err}")))?
        .to_dtype(DType::I64)
        .map_err(|err| ApiError::Internal(format!("tensor cast failed: {err}")))?;

    let mask_tensor = Tensor::from_vec(mask_vec.clone(), (1, mask_vec.len()), token_device)
        .map_err(|err| ApiError::Internal(format!("mask tensor failed: {err}")))?
        .to_dtype(DType::U8)
        .map_err(|err| ApiError::Internal(format!("mask cast failed: {err}")))?;

    let mut options = GenerateOptions::new(max_new_tokens);
    options.images_seq_mask = Some(&mask_tensor);
    if !embeddings.is_empty() {
        options.image_embeddings = Some(embeddings.as_slice());
    }
    options.eos_token_id = guard.language_model().config().eos_token_id;

    let mut _progress_guard: Option<Box<dyn Fn(usize, &[i64]) + Send + Sync>> = None;
    if let Some(controller) = &stream_controller {
        controller.send_initial();
        let callback = controller.callback();
        _progress_guard = Some(Box::new(callback));
        if let Some(cb) = _progress_guard.as_ref() {
            options.progress_callback = Some(&**cb);
        }
    }

    let generated = guard
        .generate(&input_ids, options)
        .map_err(|err| ApiError::Internal(format!("generation failed: {err:#}")))?;
    let generated_tokens = generated
        .to_vec2::<i64>()
        .map_err(|err| ApiError::Internal(format!("token decode failed: {err:#}")))?
        .into_iter()
        .next()
        .unwrap_or_default();
    let decoded = tokenizer_ref
        .decode(
            &generated_tokens
                .iter()
                .filter_map(|&id| u32::try_from(id).ok())
                .collect::<Vec<_>>(),
            true,
        )
        .unwrap_or_default();
    let normalized = normalize_text(&decoded);

    println!(
        "[generate] decoded_raw=\"{}\" normalized=\"{}\"",
        decoded
            .replace('\n', "\\n")
            .chars()
            .take(120)
            .collect::<String>(),
        normalized
            .replace('\n', "\\n")
            .chars()
            .take(120)
            .collect::<String>()
    );

    drop(guard);

    if let Some(controller) = &stream_controller {
        controller.flush_remaining(&generated_tokens);
        controller.finalize(&normalized, input_len, generated_tokens.len());
    }

    // Extract bounding boxes from the output
    let bounding_boxes = bbox::extract_bounding_boxes(&normalized)
        .unwrap_or_else(|err| {
            eprintln!("[bbox] failed to extract bounding boxes: {err}");
            Vec::new()
        });

    // Generate annotated image if we have boxes and an input image
    let annotated_image = if !bounding_boxes.is_empty() && !images.is_empty() {
        match bbox::draw_bounding_boxes(&images[0], &bounding_boxes) {
            Ok(annotated) => {
                // Encode as base64 JPEG
                let mut buffer = Vec::new();
                if let Ok(()) = annotated.write_to(&mut std::io::Cursor::new(&mut buffer), image::ImageFormat::Jpeg) {
                    Some(base64::engine::general_purpose::STANDARD.encode(&buffer))
                } else {
                    eprintln!("[bbox] failed to encode annotated image");
                    None
                }
            }
            Err(err) => {
                eprintln!("[bbox] failed to draw bounding boxes: {err}");
                None
            }
        }
    } else {
        None
    };

    // Return raw model output with all markup tags preserved
    Ok(GenerationResult {
        text: normalized,
        prompt_tokens: input_len,
        response_tokens: generated_tokens.len(),
        bounding_boxes,
        annotated_image,
    })
}

fn prepare_inputs(
    model: &DeepseekOcrModel,
    images: &[DynamicImage],
    base_size: u32,
    image_size: u32,
    crop_mode: bool,
) -> Result<Vec<OwnedVisionInput>, ApiError> {
    prepare_vision_inputs(model, images, base_size, image_size, crop_mode)
        .map_err(|err| ApiError::Internal(format!("vision input failed: {err:#}")))
}

fn convert_messages(messages: &[ApiMessage]) -> Result<(String, Vec<DynamicImage>), ApiError> {
    let latest_user_idx = messages
        .iter()
        .rposition(|message| message.role.eq_ignore_ascii_case("user"))
        .ok_or_else(|| {
            ApiError::BadRequest("request must include at least one user message".into())
        })?;

    let mut sections = Vec::new();
    let mut all_images = Vec::new();

    // OCR模型不是为对话训练的，所以只保留一轮的prompt，留多轮连正常输出都产生不了
    for message in &messages[..latest_user_idx] {
        if message.role.eq_ignore_ascii_case("system") {
            let (text, mut msg_images) = flatten_content(&message.content)?;
            if !text.is_empty() {
                sections.push(text);
            }
            all_images.append(&mut msg_images);
        }
    }

    let (user_text, mut user_images) = flatten_content(&messages[latest_user_idx].content)?;
    if !user_text.is_empty() {
        sections.push(user_text);
    }
    all_images.append(&mut user_images);

    if sections.is_empty() && all_images.is_empty() {
        return Err(ApiError::BadRequest(
            "user content must include text or images".into(),
        ));
    }

    let mut prompt = String::from("<|User|>\n");
    
    // Build the prompt body
    let body = sections.join("\n\n");
    
    // Ensure <image> tag is present when we have images
    if !all_images.is_empty() {
        let num_images = all_images.len();
        
        // Remove any existing <image> tags from body to avoid duplicates
        let body_without_image_tags = body.replace("<image>", "").trim().to_string();
        
        eprintln!("DEBUG: num_images={}, body_before_strip={:?}, body_after_strip={:?}", 
                  num_images, body, body_without_image_tags);
        
        // Add exactly one <image> tag per image at the beginning
        for _ in 0..num_images {
            prompt.push_str("<image>");
        }
        prompt.push('\n');
        
        // Add the body content
        if !body_without_image_tags.is_empty() {
            // If body doesn't have grounding tag and doesn't have special instructions, add grounding
            if !body_without_image_tags.contains("<|grounding|>") 
                && !body_without_image_tags.contains("<|ref|>") 
                && !body_without_image_tags.contains("Free OCR")
                && !body_without_image_tags.contains("Parse the figure")
                && !body_without_image_tags.contains("Locate ") {
                prompt.push_str("<|grounding|>");
            }
            prompt.push_str(&body_without_image_tags);
            if !body_without_image_tags.ends_with('\n') {
                prompt.push('\n');
            }
        } else {
            // No user text, use default grounding prompt
            prompt.push_str("<|grounding|>Convert the document to markdown.\n");
        }
    } else {
        // No images, just add the text body
        if !body.is_empty() {
            prompt.push_str(&body);
            if !body.ends_with('\n') {
                prompt.push('\n');
            }
        }
    }
    
    prompt.push_str("<|Assistant|>\n");
    
    // Debug: count <image> tags in final prompt
    let image_tag_count = prompt.matches("<image>").count();
    eprintln!("DEBUG: final_prompt has {} <image> tags, {} actual images", 
              image_tag_count, all_images.len());
    
    Ok((prompt, all_images))
}

fn flatten_content(content: &MessageContent) -> Result<(String, Vec<DynamicImage>), ApiError> {
    match content {
        MessageContent::Text(text) => {
            // Remove any <image> placeholders from the text as they will be added programmatically
            let cleaned = text.replace("<image>", "");
            let processed = ensure_grounding_enabled(cleaned.trim());
            Ok((processed, Vec::new()))
        }
        MessageContent::Parts(parts) => {
            let mut text_parts = Vec::new();
            let mut images = Vec::new();
            
            // Process parts in order to preserve text and image sequence
            for part in parts {
                match part {
                    MessagePart::ImageUrl { image_url } | MessagePart::InputImage { image_url } => {
                        images.push(load_image(image_url)?);
                    }
                    MessagePart::Text { text } | MessagePart::InputText { text } => {
                        // Remove any <image> placeholders from the text as they will be added programmatically
                        let cleaned = text.replace("<image>", "").trim().to_string();
                        if !cleaned.is_empty() {
                            text_parts.push(cleaned);
                        }
                    }
                }
            }
            
            // Combine text parts
            let combined_text = text_parts.join("\n");
            let processed = ensure_grounding_enabled(&combined_text);
            
            Ok((processed, images))
        }
    }
}

fn ensure_grounding_enabled(text: &str) -> String {
    // If the prompt already contains grounding tags or specific task instructions, leave it as-is
    if text.contains("<|grounding|>") 
        || text.contains("<|ref|>") 
        || text.contains("Free OCR")
        || text.contains("Parse the figure")
        || text.contains("Locate ")
    {
        return text.to_owned();
    }
    
    // If text is empty, return default grounding prompt (will be handled by caller to add <image>)
    if text.is_empty() {
        return String::new();
    }
    
    // If user provided custom text, preserve it as-is
    // The <image> tag will be added by flatten_content if needed
    text.to_owned()
}

fn load_image(spec: &ImagePayload) -> Result<DynamicImage, ApiError> {
    let url = spec.url();
    if let Some(rest) = url.strip_prefix("data:") {
        return load_data_url(rest);
    }
    if url.starts_with("http://") || url.starts_with("https://") {
        return fetch_remote_image(url);
    }
    Err(ApiError::BadRequest(
        "only data: URIs or http(s) image URLs are supported".into(),
    ))
}

fn load_data_url(data: &str) -> Result<DynamicImage, ApiError> {
    let (meta, payload) = data
        .split_once(',')
        .ok_or_else(|| ApiError::BadRequest("invalid data URL".into()))?;
    if !meta.ends_with(";base64") {
        return Err(ApiError::BadRequest(
            "data URLs must specify base64 encoding".into(),
        ));
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload)
        .map_err(|err| ApiError::BadRequest(format!("invalid base64 image payload: {err}")))?;
    image::load_from_memory(&decoded)
        .map_err(|err| ApiError::BadRequest(format!("failed to decode inline image: {err}")))
}

fn fetch_remote_image(url: &str) -> Result<DynamicImage, ApiError> {
    let client = Client::new();
    let response = client
        .get(url)
        .send()
        .map_err(|err| ApiError::BadRequest(format!("failed to fetch {url}: {err}")))?
        .error_for_status()
        .map_err(|err| ApiError::BadRequest(format!("image request failed for {url}: {err}")))?;
    let bytes = response
        .bytes()
        .map_err(|err| ApiError::BadRequest(format!("failed to read image body: {err}")))?;
    image::load_from_memory(&bytes)
        .map_err(|err| ApiError::BadRequest(format!("failed to decode remote image: {err}")))
}

fn prepare_config() -> Result<PathBuf> {
    assets::ensure_config()
}

fn prepare_weights(custom: Option<&PathBuf>) -> Result<PathBuf> {
    assets::resolve_weights(custom.map(PathBuf::as_path))
}

fn prepare_tokenizer(path: &Path) -> Result<Tokenizer> {
    let tokenizer_path = assets::ensure_tokenizer(path)?;
    Tokenizer::from_file(&tokenizer_path).map_err(|err| {
        anyhow!(
            "failed to load tokenizer from {}: {err}",
            tokenizer_path.display()
        )
    })
}

fn ensure_model(requested: &str, available: &str) -> Result<(), ApiError> {
    if requested == available {
        Ok(())
    } else {
        Err(ApiError::BadRequest(format!(
            "model '{}' is not available (expected '{}')",
            requested, available
        )))
    }
}

fn current_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|dur| dur.as_secs() as i64)
        .unwrap_or_default()
}

#[derive(Debug, Serialize)]
struct Usage {
    prompt_tokens: usize,
    completion_tokens: usize,
    total_tokens: usize,
}

#[derive(Debug, Serialize)]
struct ResponsesResponse {
    id: String,
    object: String,
    created: i64,
    model: String,
    output: Vec<ResponseOutput>,
    usage: Usage,
}

#[derive(Debug, Serialize)]
struct ResponseOutput {
    id: String,
    #[serde(rename = "type")]
    r#type: String,
    role: String,
    content: Vec<ResponseContent>,
}

#[derive(Debug, Serialize)]
struct ResponseContent {
    #[serde(rename = "type")]
    r#type: String,
    text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    bounding_boxes: Option<Vec<bbox::BoundingBox>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    annotated_image: Option<String>,
}

#[derive(Debug, Serialize)]
struct ChatCompletionResponse {
    id: String,
    object: String,
    created: i64,
    model: String,
    choices: Vec<ChatChoice>,
    usage: Usage,
}

#[derive(Debug, Serialize)]
struct ChatChoice {
    index: usize,
    message: ChatMessageResponse,
    finish_reason: String,
}

#[derive(Debug, Serialize)]
struct ChatMessageResponse {
    role: String,
    content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    bounding_boxes: Option<Vec<bbox::BoundingBox>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    annotated_image: Option<String>,
}

#[derive(Debug, Serialize)]
struct ModelsResponse {
    object: String,
    data: Vec<ModelInfo>,
}

#[derive(Debug, Serialize)]
struct ModelInfo {
    id: String,
    object: String,
    created: i64,
    owned_by: String,
}

#[derive(Debug)]
struct GenerationResult {
    text: String,
    prompt_tokens: usize,
    response_tokens: usize,
    bounding_boxes: Vec<bbox::BoundingBox>,
    annotated_image: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ResponsesRequest {
    model: String,
    #[serde(default)]
    input: Vec<ApiMessage>,
    #[serde(default)]
    max_output_tokens: Option<usize>,
    #[serde(default)]
    max_tokens: Option<usize>,
    #[serde(default)]
    stream: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionRequest {
    model: String,
    #[serde(default)]
    messages: Vec<ApiMessage>,
    #[serde(default)]
    max_tokens: Option<usize>,
    #[serde(default)]
    stream: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct ApiMessage {
    role: String,
    #[serde(default)]
    content: MessageContent,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum MessageContent {
    Text(String),
    Parts(Vec<MessagePart>),
}

impl Default for MessageContent {
    fn default() -> Self {
        Self::Text(String::new())
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum MessagePart {
    Text { text: String },
    InputText { text: String },
    ImageUrl { image_url: ImagePayload },
    InputImage { image_url: ImagePayload },
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum ImagePayload {
    Simple(String),
    Detailed { url: String },
}

impl ImagePayload {
    fn url(&self) -> &str {
        match self {
            ImagePayload::Simple(u) => u,
            ImagePayload::Detailed { url } => url,
        }
    }
}

#[derive(Debug, Error)]
enum ApiError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    Internal(String),
}

impl From<anyhow::Error> for ApiError {
    fn from(err: anyhow::Error) -> Self {
        ApiError::Internal(format!("{err:#}"))
    }
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: ErrorDetail,
}

#[derive(Debug, Serialize)]
struct ErrorDetail {
    message: String,
    #[serde(rename = "type")]
    r#type: String,
}

impl<'r> Responder<'r, 'static> for ApiError {
    fn respond_to(self, request: &'r rocket::Request<'_>) -> rocket::response::Result<'static> {
        // Log the error to stderr
        eprintln!("ERROR: {} - {}", request.uri(), self);
        
        let (status, error_type) = match self {
            ApiError::BadRequest(_) => (Status::BadRequest, "invalid_request_error"),
            ApiError::Internal(_) => (Status::InternalServerError, "internal_error"),
        };
        let body = ErrorBody {
            error: ErrorDetail {
                message: self.to_string(),
                r#type: error_type.to_string(),
            },
        };
        Custom(status, Json(body)).respond_to(request)
    }
}
