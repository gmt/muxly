use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use h2::client::SendRequest;
use h2::{client, server, RecvStream, SendStream};
use http::Request;
use rustls::{ClientConfig as RustlsClientConfig, RootCertStore};
use rustls_pki_types::{pem::PemObject, CertificateDer, ServerName};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::env;
use std::io::Write;
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::fs;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
    BufStream,
};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::time::{timeout, Duration};
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;
use wtransport::{ClientConfig, Endpoint, Identity, ServerConfig, VarInt};

const DEFAULT_MAX_BUFFERED_MESSAGE_BYTES: usize = 128 * 1024 * 1024;

#[derive(Debug)]
enum Command {
    HttpClient(HttpClientArgs),
    HttpServer(HttpServerArgs),
    H2Client(HttpClientArgs),
    H2SessionClient(HttpClientArgs),
    H2Server(HttpServerArgs),
    H3wtClient(H3wtClientArgs),
    H3wtSessionClient(H3wtClientArgs),
    H3wtServer(H3wtServerArgs),
}

#[derive(Debug)]
struct HttpClientArgs {
    host: String,
    port: u16,
    path: String,
    max_message_bytes: usize,
    tls: bool,
    tls_server_name: Option<String>,
    tls_ca_file: Option<String>,
    tls_sha256: Option<String>,
}

#[derive(Debug)]
struct HttpServerArgs {
    listen_host: String,
    listen_port: u16,
    path: String,
    upstream_unix: PathBuf,
    ready_file: PathBuf,
    max_message_bytes: usize,
}

#[derive(Debug)]
struct H3wtClientArgs {
    host: String,
    port: u16,
    path: String,
    sha256: Option<String>,
    tls_server_name: Option<String>,
    tls_ca_file: Option<String>,
    max_message_bytes: usize,
}

#[derive(Debug)]
struct H3wtServerArgs {
    listen_host: String,
    listen_port: u16,
    path: String,
    upstream_unix: PathBuf,
    ready_file: PathBuf,
    max_message_bytes: usize,
}

#[derive(Serialize)]
struct ReadyFile<'a> {
    host: &'a str,
    port: u16,
    path: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    sha256: Option<&'a str>,
}

#[derive(Debug)]
struct HttpRequest {
    path: String,
    body: Vec<u8>,
}

#[tokio::main]
async fn main() {
    if let Err(err) = real_main().await {
        eprintln!("{err:?}");
        std::process::exit(1);
    }
}

async fn real_main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    install_parent_death_signal()?;
    match parse_args()? {
        Command::HttpClient(args) => run_http_client(args).await,
        Command::HttpServer(args) => run_http_server(args).await,
        Command::H2Client(args) => run_h2_client(args).await,
        Command::H2SessionClient(args) => run_h2_session_client(args).await,
        Command::H2Server(args) => run_h2_server(args).await,
        Command::H3wtClient(args) => run_h3wt_client(args).await,
        Command::H3wtSessionClient(args) => run_h3wt_session_client(args).await,
        Command::H3wtServer(args) => run_h3wt_server(args).await,
    }
}

#[cfg(target_os = "linux")]
fn install_parent_death_signal() -> Result<()> {
    unsafe {
        if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
            return Err(std::io::Error::last_os_error())
                .context("unable to install bridge parent-death signal");
        }

        // If the parent already died before PR_SET_PDEATHSIG took effect,
        // Linux will not deliver a retroactive signal.
        if libc::getppid() == 1 {
            std::process::exit(1);
        }
    }

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn install_parent_death_signal() -> Result<()> {
    Ok(())
}

fn parse_args() -> Result<Command> {
    parse_args_from(env::args().skip(1))
}

fn parse_args_from<I>(mut args: I) -> Result<Command>
where
    I: Iterator<Item = String>,
{
    let subcommand = args.next().ok_or_else(|| anyhow!("missing subcommand"))?;
    let mut values: HashMap<String, String> = HashMap::new();

    while let Some(flag) = args.next() {
        if !flag.starts_with("--") {
            bail!("unexpected argument: {flag}");
        }
        let key = flag.trim_start_matches("--").to_string();
        if key == "allow-insecure" || key == "tls" {
            values.insert(key, "true".to_string());
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| anyhow!("missing value for --{key}"))?;
        values.insert(key, value);
    }

    match subcommand.as_str() {
        "http-client" => Ok(Command::HttpClient(HttpClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
            tls: values.contains_key("tls"),
            tls_server_name: values.get("tls-server-name").cloned(),
            tls_ca_file: values.get("tls-ca-file").cloned(),
            tls_sha256: values.get("tls-sha256").cloned(),
        })),
        "http-server" => Ok(Command::HttpServer(HttpServerArgs {
            listen_host: required(&values, "listen-host")?,
            listen_port: required(&values, "listen-port")?
                .parse()
                .context("invalid --listen-port")?,
            path: required(&values, "path")?,
            upstream_unix: PathBuf::from(required(&values, "upstream-unix")?),
            ready_file: PathBuf::from(required(&values, "ready-file")?),
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
        })),
        "h2-client" => Ok(Command::H2Client(HttpClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
            tls: values.contains_key("tls"),
            tls_server_name: values.get("tls-server-name").cloned(),
            tls_ca_file: values.get("tls-ca-file").cloned(),
            tls_sha256: values.get("tls-sha256").cloned(),
        })),
        "h2-session-client" => Ok(Command::H2SessionClient(HttpClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
            tls: values.contains_key("tls"),
            tls_server_name: values.get("tls-server-name").cloned(),
            tls_ca_file: values.get("tls-ca-file").cloned(),
            tls_sha256: values.get("tls-sha256").cloned(),
        })),
        "h2-server" => Ok(Command::H2Server(HttpServerArgs {
            listen_host: required(&values, "listen-host")?,
            listen_port: required(&values, "listen-port")?
                .parse()
                .context("invalid --listen-port")?,
            path: required(&values, "path")?,
            upstream_unix: PathBuf::from(required(&values, "upstream-unix")?),
            ready_file: PathBuf::from(required(&values, "ready-file")?),
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
        })),
        "h3wt-client" => Ok(Command::H3wtClient(H3wtClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            sha256: values.get("sha256").cloned(),
            tls_server_name: values.get("tls-server-name").cloned(),
            tls_ca_file: values.get("tls-ca-file").cloned(),
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
        })),
        "h3wt-session-client" => Ok(Command::H3wtSessionClient(H3wtClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            sha256: values.get("sha256").cloned(),
            tls_server_name: values.get("tls-server-name").cloned(),
            tls_ca_file: values.get("tls-ca-file").cloned(),
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
        })),
        "h3wt-server" => Ok(Command::H3wtServer(H3wtServerArgs {
            listen_host: required(&values, "listen-host")?,
            listen_port: required(&values, "listen-port")?
                .parse()
                .context("invalid --listen-port")?,
            path: required(&values, "path")?,
            upstream_unix: PathBuf::from(required(&values, "upstream-unix")?),
            ready_file: PathBuf::from(required(&values, "ready-file")?),
            max_message_bytes: optional_usize(&values, "max-message-bytes")?
                .unwrap_or(DEFAULT_MAX_BUFFERED_MESSAGE_BYTES),
        })),
        other => bail!("unknown subcommand: {other}"),
    }
}

fn required(values: &HashMap<String, String>, key: &str) -> Result<String> {
    values
        .get(key)
        .cloned()
        .ok_or_else(|| anyhow!("missing --{key}"))
}

fn optional_usize(values: &HashMap<String, String>, key: &str) -> Result<Option<usize>> {
    match values.get(key) {
        Some(value) => Ok(Some(
            value.parse().with_context(|| format!("invalid --{key}"))?,
        )),
        None => Ok(None),
    }
}

struct EstablishedTls {
    stream: TlsStream<TcpStream>,
}

async fn connect_tls_client(
    args: &HttpClientArgs,
    alpn_protocols: &[&[u8]],
) -> Result<EstablishedTls> {
    let mut roots = RootCertStore::empty();

    let native = rustls_native_certs::load_native_certs();
    for cert in native.certs {
        roots
            .add(cert)
            .context("unable to load native trust anchor")?;
    }
    for err in native.errors {
        trace(&format!("native cert load warning: {err}"));
    }

    if let Some(path) = &args.tls_ca_file {
        for cert in CertificateDer::pem_file_iter(path)
            .with_context(|| format!("unable to open CA file {path}"))?
        {
            let cert = cert.with_context(|| format!("unable to parse CA file {path}"))?;
            roots
                .add(cert)
                .with_context(|| format!("unable to add CA certificate from {path}"))?;
        }
    }

    let mut config = RustlsClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = alpn_protocols.iter().map(|value| value.to_vec()).collect();

    let connector = TlsConnector::from(Arc::new(config));
    let server_name_text = args
        .tls_server_name
        .as_deref()
        .unwrap_or(args.host.as_str())
        .to_string();
    let server_name =
        ServerName::try_from(server_name_text).map_err(|_| anyhow!("invalid TLS server name"))?;

    let tcp = TcpStream::connect((args.host.as_str(), args.port))
        .await
        .with_context(|| format!("unable to connect to {}:{}", args.host, args.port))?;
    let tls = connector
        .connect(server_name, tcp)
        .await
        .context("unable to establish TLS client session")?;
    verify_tls_pin(&tls, args.tls_sha256.as_deref())?;

    Ok(EstablishedTls { stream: tls })
}

fn verify_tls_pin(stream: &TlsStream<TcpStream>, expected_pin: Option<&str>) -> Result<()> {
    let expected_pin = match expected_pin {
        Some(value) => value,
        None => return Ok(()),
    };

    let (_, session) = stream.get_ref();
    let certs = session
        .peer_certificates()
        .ok_or_else(|| anyhow!("TLS peer certificate chain unavailable"))?;
    let end_entity = certs
        .first()
        .ok_or_else(|| anyhow!("TLS peer certificate chain empty"))?;
    let actual_pin = hex_sha256(end_entity.as_ref());
    if actual_pin != expected_pin {
        bail!("TLS certificate pin mismatch");
    }
    Ok(())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        output.push(nibble_to_hex(byte >> 4));
        output.push(nibble_to_hex(byte & 0x0f));
    }
    output
}

fn nibble_to_hex(value: u8) -> char {
    match value {
        0..=9 => (b'0' + value) as char,
        10..=15 => (b'a' + (value - 10)) as char,
        _ => unreachable!(),
    }
}

async fn run_http_client(args: HttpClientArgs) -> Result<()> {
    let host_header = host_header(&args.host, args.port);
    if args.tls {
        let tls = connect_tls_client(&args, &[b"http/1.1"]).await?;
        return run_http_client_on_stream(
            BufStream::new(tls.stream),
            &host_header,
            &args.path,
            args.max_message_bytes,
        )
        .await;
    }

    let stream = TcpStream::connect((args.host.as_str(), args.port))
        .await
        .with_context(|| format!("unable to connect to {}:{}", args.host, args.port))?;
    run_http_client_on_stream(
        BufStream::new(stream),
        &host_header,
        &args.path,
        args.max_message_bytes,
    )
    .await
}

async fn run_http_client_on_stream<S>(
    mut network: BufStream<S>,
    host_header: &str,
    path: &str,
    max_message_bytes: usize,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();

    while let Some(request_body) = read_line_message(&mut stdin, max_message_bytes).await? {
        write_http_request(&mut network, path, host_header, &request_body).await?;
        network.flush().await?;

        let response_body = read_http_response(&mut network, max_message_bytes).await?;
        stdout.write_all(&response_body).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn run_http_server(args: HttpServerArgs) -> Result<()> {
    let listener = TcpListener::bind((args.listen_host.as_str(), args.listen_port))
        .await
        .with_context(|| {
            format!(
                "unable to bind HTTP listener on {}:{}",
                args.listen_host, args.listen_port
            )
        })?;
    let local_addr = listener
        .local_addr()
        .context("missing local HTTP address")?;

    write_ready_file(
        &args.ready_file,
        ReadyFile {
            host: &args.listen_host,
            port: local_addr.port(),
            path: &args.path,
            sha256: None,
        },
    )
    .await?;

    loop {
        let (socket, _) = listener.accept().await?;
        let path = args.path.clone();
        let upstream_unix = args.upstream_unix.clone();
        let max_message_bytes = args.max_message_bytes;
        tokio::spawn(async move {
            let _ = handle_http_connection(socket, upstream_unix, path, max_message_bytes).await;
        });
    }
}

async fn handle_http_connection(
    socket: TcpStream,
    upstream_unix: PathBuf,
    path: String,
    max_message_bytes: usize,
) -> Result<()> {
    let mut client = BufStream::new(socket);

    while let Some(request) = read_http_request(&mut client, max_message_bytes).await? {
        if request.path != path {
            write_http_error(&mut client, 404, "Not Found").await?;
            client.flush().await?;
            continue;
        }

        let upstream = UnixStream::connect(&upstream_unix).await.with_context(|| {
            format!("unable to connect to upstream {}", upstream_unix.display())
        })?;
        let mut upstream = BufStream::new(upstream);
        upstream.write_all(&request.body).await?;
        upstream.write_all(b"\n").await?;
        upstream.flush().await?;

        let response = read_line_message(&mut upstream, max_message_bytes)
            .await?
            .ok_or_else(|| anyhow!("upstream closed before sending a response"))?;
        drop(upstream);
        write_http_response(&mut client, &response).await?;
        client.flush().await?;
    }

    Ok(())
}

async fn run_h2_client(args: HttpClientArgs) -> Result<()> {
    if args.tls {
        let tls = connect_tls_client(&args, &[b"h2"]).await?;
        return run_h2_client_on_stream(tls.stream, &args).await;
    }
    let stream = TcpStream::connect((args.host.as_str(), args.port))
        .await
        .with_context(|| format!("unable to connect to {}:{}", args.host, args.port))?;
    run_h2_client_on_stream(stream, &args).await
}

async fn run_h2_client_on_stream<S>(stream: S, args: &HttpClientArgs) -> Result<()>
where
    S: tokio::io::AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut builder = client::Builder::new();
    configure_h2_client_windows(&mut builder, args.max_message_bytes);
    let (sender, connection) = builder
        .handshake(stream)
        .await
        .context("unable to establish H2 client session")?;
    let connection_task = tokio::spawn(async move {
        let _ = connection.await;
    });

    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();

    while let Some(request) = read_line_message(&mut stdin, args.max_message_bytes).await? {
        trace(&format!("h2 client request bytes={}", request.len()));
        let mut response =
            send_h2_request(&sender, &args.host, args.port, &args.path, request).await?;
        copy_h2_body_to_stdout(&mut response, args.max_message_bytes, &mut stdout).await?;
    }

    connection_task.abort();
    let _ = connection_task.await;
    Ok(())
}

async fn run_h2_session_client(args: HttpClientArgs) -> Result<()> {
    if args.tls {
        let tls = connect_tls_client(&args, &[b"h2"]).await?;
        return run_h2_session_client_on_stream(tls.stream, &args).await;
    }
    let stream = TcpStream::connect((args.host.as_str(), args.port))
        .await
        .with_context(|| format!("unable to connect to {}:{}", args.host, args.port))?;
    run_h2_session_client_on_stream(stream, &args).await
}

async fn run_h2_session_client_on_stream<S>(stream: S, args: &HttpClientArgs) -> Result<()>
where
    S: tokio::io::AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    use tokio::sync::Mutex;

    let mut builder = client::Builder::new();
    configure_h2_client_windows(&mut builder, args.max_message_bytes);
    let (sender, connection) = builder
        .handshake(stream)
        .await
        .context("unable to establish H2 client session")?;
    let mut connection_task = tokio::spawn(async move {
        match connection.await {
            Ok(()) => {
                trace("h2 client connection task completed cleanly");
                Ok(())
            }
            Err(err) => {
                trace(&format!(
                    "h2 client connection task ended with error: {err:#}"
                ));
                Err(err).context("h2 client connection task failed")
            }
        }
    });

    let sender = Arc::new(Mutex::new(sender));
    let mut stdin = BufReader::new(tokio::io::stdin());
    let stdout = Arc::new(Mutex::new(tokio::io::stdout()));
    let mut tasks = tokio::task::JoinSet::new();
    let mut stdin_closed = false;
    let mut connection_done = false;

    loop {
        if stdin_closed && tasks.is_empty() {
            break;
        }

        tokio::select! {
            request_result = read_line_message(&mut stdin, args.max_message_bytes), if !stdin_closed => {
                match request_result? {
                    Some(request) => {
                        trace(&format!(
                            "h2 session client request {} bytes={}",
                            summarize_transport_payload(&request),
                            request.len()
                        ));
                        let stdout = stdout.clone();
                        let host = args.host.clone();
                        let path = args.path.clone();
                        let port = args.port;
                        let max_message_bytes = args.max_message_bytes;
                        // Keep H2 stream creation in stdin order so daemon-side FIFO lanes
                        // observe the same request ordering the client submitted.
                        let response_future = {
                            trace("h2 session client acquiring sender lock");
                            let sender = sender.lock().await;
                            trace("h2 session client sender lock acquired");
                            start_h2_request(&sender, &host, port, &path, request).await?
                        };
                        trace("h2 session client request stream started");
                        tasks.spawn(async move {
                            let mut response = timeout(Duration::from_secs(20), finish_h2_request(response_future))
                                .await
                                .context("timed out while awaiting H2 response headers")??;
                            copy_h2_body_to_shared_stdout(&mut response, max_message_bytes, stdout).await?;
                            Result::<()>::Ok(())
                        });
                    },
                    None => {
                        stdin_closed = true;
                    },
                }
            }
            task_result = tasks.join_next(), if !tasks.is_empty() => {
                match task_result {
                    Some(Ok(Ok(()))) => {},
                    Some(Ok(Err(err))) => return Err(err),
                    Some(Err(err)) => return Err(anyhow!("h2 session client task join error: {err}")),
                    None => {},
                }
            }
            connection_result = &mut connection_task, if !connection_done => {
                connection_done = true;
                connection_result
                    .context("h2 client connection task join error")??;
                if !stdin_closed || !tasks.is_empty() {
                    bail!("h2 client connection ended before requests and responses completed");
                }
            }
        }
    }

    if !connection_done {
        connection_task.abort();
        let _ = connection_task.await;
    }
    Ok(())
}

async fn run_h2_server(args: HttpServerArgs) -> Result<()> {
    let lanes = Arc::new(tokio::sync::Mutex::new(HashMap::<
        UpstreamLaneKey,
        Arc<LaneQueue>,
    >::new()));
    let body_read_queue = Arc::new(OrderedSequenceGate::default());
    let next_accept_sequence = Arc::new(AtomicU64::new(1));
    let listener = TcpListener::bind((args.listen_host.as_str(), args.listen_port))
        .await
        .with_context(|| {
            format!(
                "unable to bind H2 listener on {}:{}",
                args.listen_host, args.listen_port
            )
        })?;
    let local_addr = listener.local_addr().context("missing local H2 address")?;

    write_ready_file(
        &args.ready_file,
        ReadyFile {
            host: &args.listen_host,
            port: local_addr.port(),
            path: &args.path,
            sha256: None,
        },
    )
    .await?;

    loop {
        let (socket, _) = listener.accept().await?;
        trace("h2 server accepted tcp connection");
        let path = args.path.clone();
        let upstream_unix = args.upstream_unix.clone();
        let max_message_bytes = args.max_message_bytes;
        let lanes = lanes.clone();
        let body_read_queue = body_read_queue.clone();
        let next_accept_sequence = next_accept_sequence.clone();
        tokio::spawn(async move {
            let _ = handle_h2_connection(
                socket,
                upstream_unix,
                path,
                max_message_bytes,
                lanes,
                body_read_queue,
                next_accept_sequence,
            )
            .await;
        });
    }
}

async fn handle_h2_connection(
    socket: TcpStream,
    upstream_unix: PathBuf,
    path: String,
    max_message_bytes: usize,
    lanes: Arc<tokio::sync::Mutex<HashMap<UpstreamLaneKey, Arc<LaneQueue>>>>,
    body_read_queue: Arc<OrderedSequenceGate>,
    next_accept_sequence: Arc<AtomicU64>,
) -> Result<()> {
    let mut builder = server::Builder::new();
    configure_h2_server_windows(&mut builder, max_message_bytes);
    trace("h2 server starting session handshake");
    let mut connection = builder
        .handshake(socket)
        .await
        .context("unable to establish H2C server session")?;
    trace("h2 server session handshake complete");

    trace("h2 server waiting for request stream");
    while let Some(result) = connection.accept().await {
        trace("h2 server accepted stream");
        let (request, respond) = result?;
        let expected_path = path.clone();
        let upstream_unix = upstream_unix.clone();
        let lanes = lanes.clone();
        let body_read_queue = body_read_queue.clone();
        let accept_sequence = next_accept_sequence.fetch_add(1, Ordering::Relaxed);
        tokio::spawn(async move {
            let active = match start_h2_stream(
                request,
                respond,
                upstream_unix,
                expected_path,
                max_message_bytes,
                lanes,
                body_read_queue,
                accept_sequence,
            )
            .await
            {
                Ok(active) => active,
                Err(err) => {
                    trace(&format!("h2 server request setup failed: {err:#}"));
                    return;
                }
            };

            if let Err(err) = finish_server_h2_stream(active, max_message_bytes).await {
                trace(&format!("h2 server response forwarding failed: {err:#}"));
            }
        });
        trace("h2 server waiting for request stream");
    }

    trace("h2 server session ended");
    Ok(())
}

struct ActiveServerH2Stream {
    upstream: BufStream<UnixStream>,
    send: SendStream<Bytes>,
    trace_summary: String,
    lane_guard: Option<LaneGuard>,
}

struct OrderedSequenceGate {
    state: std::sync::Mutex<OrderedSequenceGateState>,
    notify: tokio::sync::Notify,
}

struct OrderedSequenceGateState {
    busy: bool,
    next_sequence: u64,
}

struct OrderedSequenceGuard {
    gate: Arc<OrderedSequenceGate>,
}

impl Default for OrderedSequenceGate {
    fn default() -> Self {
        return Self {
            state: std::sync::Mutex::new(OrderedSequenceGateState {
                busy: false,
                next_sequence: 1,
            }),
            notify: tokio::sync::Notify::new(),
        };
    }
}

impl OrderedSequenceGate {
    async fn acquire(self: &Arc<OrderedSequenceGate>, sequence: u64) -> OrderedSequenceGuard {
        loop {
            let notified = self.notify.notified();
            {
                let mut state = self
                    .state
                    .lock()
                    .expect("ordered sequence gate mutex poisoned");
                if !state.busy && state.next_sequence == sequence {
                    state.busy = true;
                    return OrderedSequenceGuard { gate: self.clone() };
                }
            }

            notified.await;
        }
    }

    fn release(&self) {
        {
            let mut state = self
                .state
                .lock()
                .expect("ordered sequence gate mutex poisoned");
            state.busy = false;
            state.next_sequence += 1;
        }
        self.notify.notify_waiters();
    }
}

impl Drop for OrderedSequenceGuard {
    fn drop(&mut self) {
        self.gate.release();
    }
}

#[derive(Default)]
struct LaneQueue {
    state: std::sync::Mutex<LaneQueueState>,
    notify: tokio::sync::Notify,
}

#[derive(Default)]
struct LaneQueueState {
    busy: bool,
    waiting_sequences: BTreeSet<u64>,
}

struct LaneGuard {
    queue: Arc<LaneQueue>,
}

impl LaneQueue {
    async fn acquire(self: &Arc<LaneQueue>, sequence: u64) -> LaneGuard {
        {
            let mut state = self.state.lock().expect("lane queue mutex poisoned");
            let _ = state.waiting_sequences.insert(sequence);
        }

        loop {
            let notified = self.notify.notified();
            {
                let mut state = self.state.lock().expect("lane queue mutex poisoned");
                if !state.busy && state.waiting_sequences.first().copied() == Some(sequence) {
                    state.busy = true;
                    let _ = state.waiting_sequences.remove(&sequence);
                    return LaneGuard {
                        queue: self.clone(),
                    };
                }
            }

            notified.await;
        }
    }

    fn release(&self) {
        {
            let mut state = self.state.lock().expect("lane queue mutex poisoned");
            state.busy = false;
        }
        self.notify.notify_waiters();
    }
}

impl Drop for LaneGuard {
    fn drop(&mut self) {
        self.queue.release();
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
enum UpstreamLaneKey {
    Root,
    Document(String),
}

async fn start_h2_stream(
    request: Request<RecvStream>,
    mut respond: server::SendResponse<Bytes>,
    upstream_unix: PathBuf,
    expected_path: String,
    max_message_bytes: usize,
    lanes: Arc<tokio::sync::Mutex<HashMap<UpstreamLaneKey, Arc<LaneQueue>>>>,
    body_read_queue: Arc<OrderedSequenceGate>,
    accept_sequence: u64,
) -> Result<ActiveServerH2Stream> {
    if request.uri().path() != expected_path {
        send_h2_error_response(&mut respond, 404)?;
        bail!("unexpected H2 path: {}", request.uri().path());
    }

    let body_read_guard = body_read_queue.acquire(accept_sequence).await;
    trace("h2 server reading request body");
    let request = match read_h2_request_body(request, max_message_bytes).await {
        Ok(request) => request,
        Err(err) => {
            let _ = send_h2_error_response(&mut respond, 400);
            return Err(err);
        }
    };
    drop(body_read_guard);
    trace("h2 server request body read");
    let lane_key = classify_upstream_lane_key(&request);
    let lane_queue = {
        let mut lane_map = lanes.lock().await;
        lane_map
            .entry(lane_key)
            .or_insert_with(|| Arc::new(LaneQueue::default()))
            .clone()
    };
    trace("h2 server waiting for lane lock");
    let lane_guard = lane_queue.acquire(accept_sequence).await;
    trace("h2 server lane lock acquired");
    let hold_lane_until_response_complete = !request_is_stream_open(&request);
    let trace_summary = summarize_transport_payload(&request);
    trace(&format!(
        "h2 server request {} bytes={}",
        trace_summary,
        request.len()
    ));

    let upstream = match UnixStream::connect(&upstream_unix)
        .await
        .with_context(|| format!("unable to connect to upstream {}", upstream_unix.display()))
    {
        Ok(upstream) => upstream,
        Err(err) => {
            let _ = send_h2_error_response(&mut respond, 502);
            return Err(err);
        }
    };
    let mut upstream = BufStream::new(upstream);
    if let Err(err) = upstream.write_all(&request).await {
        let _ = send_h2_error_response(&mut respond, 502);
        return Err(err.into());
    }
    if let Err(err) = upstream.write_all(b"\n").await {
        let _ = send_h2_error_response(&mut respond, 502);
        return Err(err.into());
    }
    if let Err(err) = upstream.flush().await {
        let _ = send_h2_error_response(&mut respond, 502);
        return Err(err.into());
    }

    let response = http::Response::builder()
        .status(200)
        .body(())
        .context("unable to build H2 response")?;
    let send = respond.send_response(response, false)?;

    Ok(ActiveServerH2Stream {
        upstream,
        send,
        trace_summary,
        lane_guard: if hold_lane_until_response_complete {
            Some(lane_guard)
        } else {
            None
        },
    })
}

async fn finish_server_h2_stream(
    mut active: ActiveServerH2Stream,
    max_message_bytes: usize,
) -> Result<()> {
    let mut wrote_response = false;
    while let Some(response) = read_line_message(&mut active.upstream, max_message_bytes).await? {
        trace(&format!(
            "h2 server response {} bytes={}",
            active.trace_summary,
            response.len()
        ));
        wrote_response = true;
        active.send.send_data(Bytes::from(response), false)?;
        active.send.send_data(Bytes::from_static(b"\n"), false)?;
    }
    if !wrote_response {
        bail!("upstream closed before sending a response");
    }

    active.send.send_data(Bytes::new(), true)?;
    drop(active.lane_guard.take());
    Ok(())
}

fn send_h2_error_response(respond: &mut server::SendResponse<Bytes>, status: u16) -> Result<()> {
    let response = http::Response::builder()
        .status(status)
        .body(())
        .with_context(|| format!("unable to build H2 {status} response"))?;
    let mut send = respond.send_response(response, false)?;
    send.send_data(Bytes::new(), true)?;
    Ok(())
}

async fn send_h2_request(
    sender: &SendRequest<Bytes>,
    host: &str,
    port: u16,
    path: &str,
    request: Vec<u8>,
) -> Result<RecvStream> {
    let response = start_h2_request(sender, host, port, path, request).await?;
    finish_h2_request(response).await
}

async fn start_h2_request(
    sender: &SendRequest<Bytes>,
    host: &str,
    port: u16,
    path: &str,
    mut request: Vec<u8>,
) -> Result<client::ResponseFuture> {
    trace("h2 client waiting for ready sender");
    let mut sender = sender.clone().ready().await?;
    trace("h2 client sender ready");
    let request_head = Request::builder()
        .method("POST")
        .uri(format!("http://{}{}", authority(host, port), path))
        .body(())
        .context("unable to build H2 request")?;
    trace("h2 client sending request head");
    let (response, mut send_stream) = sender.send_request(request_head, false)?;
    trace("h2 client request head sent");
    request.push(b'\n');
    send_stream.send_data(Bytes::from(request), true)?;
    trace("h2 client request body sent");
    tokio::task::yield_now().await;

    Ok(response)
}

async fn finish_h2_request(response: client::ResponseFuture) -> Result<RecvStream> {
    trace("h2 client waiting for response headers");
    let response = response.await?;
    trace(&format!(
        "h2 client received response status={}",
        response.status()
    ));
    if response.status() != 200 {
        bail!("unexpected H2 status {}", response.status());
    }
    Ok(response.into_body())
}

async fn run_h3wt_client(args: H3wtClientArgs) -> Result<()> {
    let (client_config, url_host) = build_h3wt_client_config(&args).await?;
    let endpoint = Endpoint::client(client_config)?;
    let url = format!(
        "https://{}{}{}",
        authority(&url_host, args.port),
        args.path,
        ""
    );
    let connection = timeout(Duration::from_secs(5), endpoint.connect(&url))
        .await
        .context("timed out while connecting WebTransport session")??;
    verify_h3wt_pin(&connection, args.sha256.as_deref())?;
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();

    while let Some(request) = read_line_message(&mut stdin, args.max_message_bytes).await? {
        trace(&format!("h3wt client request bytes={}", request.len()));
        let stream = timeout(Duration::from_secs(5), connection.open_bi())
            .await
            .context("timed out while opening WebTransport request stream")??;
        let (mut send_stream, recv_stream) = timeout(Duration::from_secs(5), stream)
            .await
            .context("timed out while awaiting WebTransport request stream readiness")??;

        send_stream.write_all(&request).await?;
        send_stream.write_all(b"\n").await?;
        send_stream.flush().await?;
        send_stream.finish().await?;
        tokio::task::yield_now().await;

        let mut recv_reader = BufReader::new(recv_stream);
        while let Some(response) =
            read_line_message(&mut recv_reader, args.max_message_bytes).await?
        {
            trace(&format!("h3wt client response bytes={}", response.len()));
            stdout.write_all(&response).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }

    connection.close(VarInt::from_u32(0), b"muxly client done");
    let _ = timeout(Duration::from_secs(1), connection.closed()).await;

    Ok(())
}

async fn run_h3wt_session_client(args: H3wtClientArgs) -> Result<()> {
    use std::sync::Arc;
    use tokio::sync::Mutex;

    let (client_config, url_host) = build_h3wt_client_config(&args).await?;
    let endpoint = Endpoint::client(client_config)?;
    let url = format!(
        "https://{}{}{}",
        authority(&url_host, args.port),
        args.path,
        ""
    );
    let connection = timeout(Duration::from_secs(5), endpoint.connect(&url))
        .await
        .context("timed out while connecting WebTransport session")??;
    verify_h3wt_pin(&connection, args.sha256.as_deref())?;
    let mut stdin = BufReader::new(tokio::io::stdin());
    let stdout = Arc::new(Mutex::new(tokio::io::stdout()));
    let mut tasks = tokio::task::JoinSet::new();
    let mut stdin_closed = false;

    loop {
        if stdin_closed && tasks.is_empty() {
            break;
        }

        tokio::select! {
            request_result = read_line_message(&mut stdin, args.max_message_bytes), if !stdin_closed => {
                match request_result? {
                    Some(request) => {
                        trace(&format!(
                            "h3wt session client request bytes={}",
                            request.len()
                        ));
                        let connection = connection.clone();
                        let stdout = stdout.clone();
                        tasks.spawn(async move {
                            let stream = timeout(Duration::from_secs(5), connection.open_bi())
                                .await
                                .context("timed out while opening WebTransport request stream")??;
                            let (mut send_stream, recv_stream) =
                                timeout(Duration::from_secs(5), stream)
                                    .await
                                    .context("timed out while awaiting WebTransport request stream readiness")??;

                            send_stream.write_all(&request).await?;
                            send_stream.write_all(b"\n").await?;
                            send_stream.flush().await?;
                            send_stream.finish().await?;

                            let mut recv_reader = BufReader::new(recv_stream);
                            while let Some(response) =
                                read_line_message(&mut recv_reader, args.max_message_bytes).await?
                            {
                                trace(&format!(
                                    "h3wt session client response bytes={}",
                                    response.len()
                                ));

                                let mut stdout = stdout.lock().await;
                                stdout.write_all(&response).await?;
                                stdout.write_all(b"\n").await?;
                                stdout.flush().await?;
                            }
                            Result::<()>::Ok(())
                        });
                    },
                    None => {
                        stdin_closed = true;
                    },
                }
            }
            task_result = tasks.join_next(), if !tasks.is_empty() => {
                match task_result {
                    Some(Ok(Ok(()))) => {},
                    Some(Ok(Err(err))) => return Err(err),
                    Some(Err(err)) => return Err(anyhow!("h3wt session client task join error: {err}")),
                    None => {},
                }
            }
        }
    }

    connection.close(VarInt::from_u32(0), b"muxly client done");
    let _ = timeout(Duration::from_secs(1), connection.closed()).await;

    Ok(())
}

async fn run_h3wt_server(args: H3wtServerArgs) -> Result<()> {
    let identity = load_or_create_identity(&args.listen_host).await?;
    let sha256 = identity.certificate_chain().as_slice()[0]
        .hash()
        .to_string();
    let bind_addr = resolve_socket_addr(&args.listen_host, args.listen_port)?;
    let config = ServerConfig::builder()
        .with_bind_address(bind_addr)
        .with_identity(identity)
        .build();
    let endpoint = Endpoint::server(config)?;
    let local_addr = endpoint
        .local_addr()
        .context("missing local WebTransport address")?;

    write_ready_file(
        &args.ready_file,
        ReadyFile {
            host: &args.listen_host,
            port: local_addr.port(),
            path: &args.path,
            sha256: Some(&sha256),
        },
    )
    .await?;

    loop {
        let incoming = endpoint.accept().await;
        let expected_path = args.path.clone();
        let upstream_unix = args.upstream_unix.clone();
        let max_message_bytes = args.max_message_bytes;
        tokio::spawn(async move {
            let _ = handle_h3wt_session(incoming, expected_path, upstream_unix, max_message_bytes)
                .await;
        });
    }
}

async fn handle_h3wt_session(
    incoming: wtransport::endpoint::IncomingSession,
    expected_path: String,
    upstream_unix: PathBuf,
    max_message_bytes: usize,
) -> Result<()> {
    let session_request = incoming.await?;
    if session_request.path() != expected_path {
        bail!("unexpected WebTransport path: {}", session_request.path());
    }

    let connection = session_request.accept().await?;

    loop {
        let bi_stream = connection.accept_bi().await?;
        let upstream_unix = upstream_unix.clone();
        let max_message_bytes = max_message_bytes;
        tokio::spawn(async move {
            let _ = handle_h3wt_bi_stream(bi_stream, upstream_unix, max_message_bytes).await;
        });
    }
}

async fn handle_h3wt_bi_stream(
    mut bi_stream: (wtransport::SendStream, wtransport::RecvStream),
    upstream_unix: PathBuf,
    max_message_bytes: usize,
) -> Result<()> {
    let mut request_reader = BufReader::new(bi_stream.1);
    let request = read_line_message(&mut request_reader, max_message_bytes)
        .await?
        .ok_or_else(|| anyhow!("missing WebTransport request body"))?;
    trace(&format!("h3wt server request bytes={}", request.len()));
    tokio::task::yield_now().await;

    let upstream = UnixStream::connect(&upstream_unix)
        .await
        .with_context(|| format!("unable to connect to upstream {}", upstream_unix.display()))?;
    let mut upstream = BufStream::new(upstream);
    upstream.write_all(&request).await?;
    upstream.write_all(b"\n").await?;
    upstream.flush().await?;

    let mut wrote_response = false;
    while let Some(response) = read_line_message(&mut upstream, max_message_bytes).await? {
        trace(&format!("h3wt server response bytes={}", response.len()));
        wrote_response = true;
        tokio::task::yield_now().await;
        bi_stream.0.write_all(&response).await?;
        bi_stream.0.write_all(b"\n").await?;
        bi_stream.0.flush().await?;
    }
    if !wrote_response {
        bail!("upstream closed before sending a response");
    }
    bi_stream.0.finish().await?;
    tokio::task::yield_now().await;
    Ok(())
}

#[derive(Debug)]
struct H3wtOverrideResolver {
    connect_host: String,
}

impl wtransport::config::DnsResolver for H3wtOverrideResolver {
    fn resolve(&self, host: &str) -> Pin<Box<dyn wtransport::config::DnsLookupFuture>> {
        let connect_host = self.connect_host.clone();
        let port = extract_lookup_port(host);

        Box::pin(async move {
            let Some(port) = port else {
                return Ok(None);
            };
            Ok(tokio::net::lookup_host((connect_host.as_str(), port))
                .await?
                .next())
        })
    }
}

fn extract_lookup_port(host: &str) -> Option<u16> {
    if let Some(stripped) = host.strip_prefix('[') {
        let close = stripped.find(']')?;
        let remainder = stripped.get(close + 1..)?;
        let port_text = remainder.strip_prefix(':')?;
        return port_text.parse().ok();
    }

    let (_, port_text) = host.rsplit_once(':')?;
    port_text.parse().ok()
}

async fn build_h3wt_client_config(args: &H3wtClientArgs) -> Result<(ClientConfig, String)> {
    let builder = ClientConfig::builder().with_bind_default();
    let mut client_config = if args.sha256.is_some() && args.tls_ca_file.is_none() {
        builder
            .with_server_certificate_hashes([args
                .sha256
                .as_deref()
                .unwrap()
                .parse()
                .context("invalid --sha256 hash")?])
            .build()
    } else {
        let mut roots = RootCertStore::empty();
        let native = rustls_native_certs::load_native_certs();
        for cert in native.certs {
            roots
                .add(cert)
                .context("unable to load native trust anchor")?;
        }
        for err in native.errors {
            trace(&format!("native cert load warning: {err}"));
        }

        if let Some(path) = &args.tls_ca_file {
            for cert in CertificateDer::pem_file_iter(path)
                .with_context(|| format!("unable to open CA file {path}"))?
            {
                let cert = cert.with_context(|| format!("unable to parse CA file {path}"))?;
                roots
                    .add(cert)
                    .with_context(|| format!("unable to add CA certificate from {path}"))?;
            }
        }

        let tls_config = RustlsClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        builder.with_custom_tls(tls_config).build()
    };

    let url_host = args
        .tls_server_name
        .as_deref()
        .unwrap_or(args.host.as_str())
        .to_string();
    if args.tls_server_name.is_some() && args.tls_server_name.as_deref() != Some(args.host.as_str())
    {
        client_config.set_dns_resolver(H3wtOverrideResolver {
            connect_host: args.host.clone(),
        });
    }

    Ok((client_config, url_host))
}

fn verify_h3wt_pin(connection: &wtransport::Connection, expected_pin: Option<&str>) -> Result<()> {
    let expected_pin = match expected_pin {
        Some(value) => value,
        None => return Ok(()),
    };

    let identity = connection
        .peer_identity()
        .ok_or_else(|| anyhow!("WebTransport peer certificate chain unavailable"))?;
    let end_entity = identity
        .as_slice()
        .first()
        .ok_or_else(|| anyhow!("WebTransport peer certificate chain empty"))?;
    let actual_pin = end_entity.hash().to_string();
    if actual_pin != expected_pin {
        bail!("WebTransport certificate pin mismatch");
    }
    Ok(())
}

async fn load_or_create_identity(listen_host: &str) -> Result<Identity> {
    if let (Ok(cert_path), Ok(key_path)) = (env::var("MUXLY_H3WT_CERT"), env::var("MUXLY_H3WT_KEY"))
    {
        return Identity::load_pemfiles(cert_path, key_path)
            .await
            .context("unable to load MUXLY_H3WT_CERT/MUXLY_H3WT_KEY");
    }

    let (cert_path, key_path) = identity_paths()?;
    if cert_path.exists() && key_path.exists() {
        return Identity::load_pemfiles(&cert_path, &key_path)
            .await
            .with_context(|| format!("unable to load {}", cert_path.display()));
    }

    if let Some(parent) = cert_path.parent() {
        fs::create_dir_all(parent).await?;
    }
    if let Some(parent) = key_path.parent() {
        fs::create_dir_all(parent).await?;
    }

    let mut names = vec![
        "localhost".to_string(),
        "127.0.0.1".to_string(),
        "::1".to_string(),
    ];
    if !listen_host.is_empty()
        && listen_host != "0.0.0.0"
        && listen_host != "::"
        && !names.iter().any(|value| value == listen_host)
    {
        names.push(listen_host.to_string());
    }

    let identity = Identity::self_signed(names)?;
    identity
        .certificate_chain()
        .store_pemfile(&cert_path)
        .await?;
    identity
        .private_key()
        .store_secret_pemfile(&key_path)
        .await?;
    Ok(identity)
}

fn identity_paths() -> Result<(PathBuf, PathBuf)> {
    if let Ok(dir) = env::var("MUXLY_H3WT_IDENTITY_DIR") {
        let base = PathBuf::from(dir);
        return Ok((base.join("cert.pem"), base.join("key.pem")));
    }

    if let Ok(state_home) = env::var("XDG_STATE_HOME") {
        let base = PathBuf::from(state_home).join("muxly");
        return Ok((base.join("h3wt-cert.pem"), base.join("h3wt-key.pem")));
    }

    let home = env::var("HOME").context("HOME is not set")?;
    let base = PathBuf::from(home).join(".local/state/muxly");
    Ok((base.join("h3wt-cert.pem"), base.join("h3wt-key.pem")))
}

async fn write_ready_file(path: &Path, ready: ReadyFile<'_>) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    let bytes = serde_json::to_vec_pretty(&ready)?;
    fs::write(path, bytes).await?;
    Ok(())
}

fn resolve_socket_addr(host: &str, port: u16) -> Result<SocketAddr> {
    (host, port)
        .to_socket_addrs()
        .context("unable to resolve socket address")?
        .next()
        .ok_or_else(|| anyhow!("no resolved socket address"))
}

fn authority(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn host_header(host: &str, port: u16) -> String {
    authority(host, port)
}

struct H2LineDecoder {
    buffer: Vec<u8>,
    max_message_bytes: usize,
}

impl H2LineDecoder {
    fn new(max_message_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_message_bytes,
        }
    }

    fn push_chunk(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>> {
        self.buffer.extend_from_slice(chunk);
        if self.buffer.len() > self.max_message_bytes {
            bail!(
                "message exceeds buffered bridge cap of {} bytes",
                self.max_message_bytes
            );
        }

        let mut lines = Vec::new();
        while let Some(index) = self.buffer.iter().position(|&byte| byte == b'\n') {
            let mut line = self.buffer.drain(..=index).collect::<Vec<u8>>();
            if line.last().copied() == Some(b'\n') {
                line.pop();
            }
            if line.last().copied() == Some(b'\r') {
                line.pop();
            }
            lines.push(line);
        }
        Ok(lines)
    }

    fn finish(&mut self) -> Vec<Vec<u8>> {
        if self.buffer.is_empty() {
            return Vec::new();
        }
        vec![std::mem::take(&mut self.buffer)]
    }
}

async fn read_h2_request_body(
    request: Request<RecvStream>,
    max_message_bytes: usize,
) -> Result<Vec<u8>> {
    let mut body = request.into_body();
    let mut decoder = H2LineDecoder::new(max_message_bytes);

    while let Some(chunk) = body.data().await {
        let mut lines = decoder.push_chunk(&chunk?)?;
        match lines.len() {
            0 => {}
            1 => return Ok(lines.pop().expect("single line should exist")),
            _ => bail!("H2 request body contained multiple logical messages"),
        }
    }

    let mut lines = decoder.finish();

    match lines.len() {
        0 => bail!("missing H2 request body"),
        1 => Ok(lines.pop().expect("single line should exist")),
        _ => bail!("H2 request body contained multiple logical messages"),
    }
}

async fn copy_h2_body_to_stdout(
    body: &mut RecvStream,
    max_message_bytes: usize,
    stdout: &mut tokio::io::Stdout,
) -> Result<()> {
    let mut decoder = H2LineDecoder::new(max_message_bytes);
    while let Some(chunk) = body.data().await {
        for line in decoder.push_chunk(&chunk?)? {
            trace(&format!("h2 client response bytes={}", line.len()));
            stdout.write_all(&line).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }

    for line in decoder.finish() {
        trace(&format!("h2 client response bytes={}", line.len()));
        stdout.write_all(&line).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn copy_h2_body_to_shared_stdout(
    body: &mut RecvStream,
    max_message_bytes: usize,
    stdout: std::sync::Arc<tokio::sync::Mutex<tokio::io::Stdout>>,
) -> Result<()> {
    let mut decoder = H2LineDecoder::new(max_message_bytes);
    while let Some(chunk) = body.data().await {
        for line in decoder.push_chunk(&chunk?)? {
            trace(&format!(
                "h2 session client response {} bytes={}",
                summarize_transport_payload(&line),
                line.len()
            ));
            let mut stdout = stdout.lock().await;
            stdout.write_all(&line).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }

    for line in decoder.finish() {
        trace(&format!(
            "h2 session client response {} bytes={}",
            summarize_transport_payload(&line),
            line.len()
        ));
        let mut stdout = stdout.lock().await;
        stdout.write_all(&line).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn read_line_message<R>(reader: &mut R, max_message_bytes: usize) -> Result<Option<Vec<u8>>>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    let bytes_read = read_line_message_with_cap(reader, &mut line, max_message_bytes).await?;
    if bytes_read == 0 {
        return Ok(None);
    }
    if line.last().copied() == Some(b'\n') {
        line.pop();
    }
    if line.last().copied() == Some(b'\r') {
        line.pop();
    }
    Ok(Some(line))
}

async fn read_line_message_with_cap<R>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
    max_bytes: usize,
) -> Result<usize>
where
    R: AsyncBufRead + Unpin,
{
    let mut limited = reader.take((max_bytes + 1) as u64);
    let bytes_read = limited.read_until(b'\n', buffer).await?;
    if buffer.len() > max_bytes {
        bail!("message exceeds buffered bridge cap of {max_bytes} bytes");
    }
    Ok(bytes_read)
}

async fn read_http_request<R>(
    reader: &mut R,
    max_message_bytes: usize,
) -> Result<Option<HttpRequest>>
where
    R: AsyncBufRead + Unpin,
{
    let request_line;
    loop {
        let Some(line) = read_http_line(reader, max_message_bytes).await? else {
            return Ok(None);
        };
        if line == "\r\n" {
            continue;
        }
        request_line = line;
        break;
    }

    let mut parts = request_line.trim_end().split_whitespace();
    let method = parts.next().ok_or_else(|| anyhow!("missing HTTP method"))?;
    let path = parts.next().ok_or_else(|| anyhow!("missing HTTP path"))?;
    let version = parts
        .next()
        .ok_or_else(|| anyhow!("missing HTTP version"))?;
    if method != "POST" || !version.starts_with("HTTP/1.1") {
        bail!("unsupported HTTP request line: {request_line}");
    }

    let mut content_length: Option<usize> = None;
    loop {
        let Some(line) = read_http_line(reader, max_message_bytes).await? else {
            bail!("unexpected EOF while reading HTTP headers");
        };
        if line == "\r\n" {
            break;
        }

        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(parse_content_length(value.trim(), max_message_bytes)?);
            }
        }
    }

    let content_length = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).await?;
    Ok(Some(HttpRequest {
        path: path.to_string(),
        body,
    }))
}

async fn read_http_response<R>(reader: &mut R, max_message_bytes: usize) -> Result<Vec<u8>>
where
    R: AsyncBufRead + Unpin,
{
    let Some(status_line) = read_http_line(reader, max_message_bytes).await? else {
        bail!("unexpected EOF while reading HTTP response");
    };
    if !status_line.starts_with("HTTP/1.1 200") {
        bail!("unexpected HTTP status line: {}", status_line.trim_end());
    }

    let mut content_length: Option<usize> = None;
    loop {
        let Some(line) = read_http_line(reader, max_message_bytes).await? else {
            bail!("unexpected EOF while reading HTTP response headers");
        };
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(parse_content_length(value.trim(), max_message_bytes)?);
            }
        }
    }

    let content_length = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).await?;
    Ok(body)
}

async fn read_http_line<R>(reader: &mut R, max_message_bytes: usize) -> Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    let bytes_read = read_line_message_with_cap(reader, &mut line, max_message_bytes).await?;
    if bytes_read == 0 {
        return Ok(None);
    }
    Ok(Some(
        String::from_utf8(line).context("HTTP line is not valid UTF-8")?,
    ))
}

fn parse_content_length(value: &str, max_message_bytes: usize) -> Result<usize> {
    let content_length: usize = value.parse().context("invalid Content-Length")?;
    if content_length > max_message_bytes {
        bail!(
            "HTTP body exceeds buffered bridge cap of {} bytes",
            max_message_bytes
        );
    }
    Ok(content_length)
}

async fn write_http_request<W>(writer: &mut W, path: &str, host: &str, body: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "POST {path} HTTP/1.1\r\nHost: {host}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .as_bytes(),
        )
        .await?;
    writer.write_all(body).await?;
    Ok(())
}

async fn write_http_response<W>(writer: &mut W, body: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .as_bytes(),
        )
        .await?;
    writer.write_all(body).await?;
    Ok(())
}

async fn write_http_error<W>(writer: &mut W, status: u16, message: &str) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "HTTP/1.1 {status} {message}\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"
            )
            .as_bytes(),
        )
        .await?;
    Ok(())
}

fn trace(message: &str) {
    let line = format!(
        "[muxly-transport-bridge pid={}] {message}",
        std::process::id()
    );
    if env::var_os("MUXLY_TRANSPORT_BRIDGE_TRACE").is_some() {
        eprintln!("{line}");
    }
    if let Some(path) = env::var_os("MUXLY_TRANSPORT_BRIDGE_TRACE_FILE") {
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }
}

fn classify_upstream_lane_key(bytes: &[u8]) -> UpstreamLaneKey {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return UpstreamLaneKey::Root;
    };

    let request_value = value
        .get("payload")
        .filter(|payload| payload.get("method").is_some())
        .unwrap_or(&value);

    let document_path = request_value
        .get("target")
        .and_then(|target| target.get("documentPath"))
        .and_then(|entry| entry.as_str())
        .unwrap_or("/");
    if document_path == "/" {
        return UpstreamLaneKey::Root;
    }

    let method = request_value
        .get("method")
        .and_then(|entry| entry.as_str())
        .unwrap_or("");
    if !request_runs_on_document_lane(method, request_value.get("params")) {
        return UpstreamLaneKey::Root;
    }

    UpstreamLaneKey::Document(document_path.to_string())
}

fn request_runs_on_document_lane(method: &str, params: Option<&serde_json::Value>) -> bool {
    matches!(
        method,
        "document.get"
            | "graph.get"
            | "view.get"
            | "projection.get"
            | "document.status"
            | "document.serialize"
            | "document.freeze"
            | "debug.sleep"
            | "node.get"
            | "node.append"
            | "node.update"
            | "node.freeze"
            | "node.remove"
            | "view.setRoot"
            | "view.clearRoot"
            | "view.elide"
            | "view.expand"
            | "view.reset"
            | "leaf.source.get"
            | "file.capture"
            | "file.followTail"
    ) || (method == "leaf.source.attach"
        && params
            .and_then(|value| value.get("kind"))
            .and_then(|entry| entry.as_str())
            .map(|kind| kind == "static-file" || kind == "monitored-file")
            .unwrap_or(false))
}

fn summarize_transport_payload(bytes: &[u8]) -> String {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return "non-json".to_string();
    };

    let conversation_id = value
        .get("conversationId")
        .and_then(|entry| entry.as_str())
        .unwrap_or("?");
    let request_id = value
        .get("requestId")
        .and_then(|entry| entry.as_u64())
        .map(|id| id.to_string())
        .unwrap_or_else(|| "?".to_string());
    let method = value
        .get("payload")
        .and_then(|payload| payload.get("method"))
        .and_then(|entry| entry.as_str())
        .unwrap_or("?");
    let document_path = value
        .get("target")
        .and_then(|target| target.get("documentPath"))
        .or_else(|| {
            value
                .get("payload")
                .and_then(|payload| payload.get("target"))
                .and_then(|target| target.get("documentPath"))
        })
        .and_then(|entry| entry.as_str())
        .unwrap_or("?");

    format!(
        "conversation={} request={} method={} document={}",
        conversation_id, request_id, method, document_path
    )
}

fn request_is_stream_open(bytes: &[u8]) -> bool {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return false;
    };

    value
        .get("payload")
        .and_then(|payload| payload.get("method"))
        .or_else(|| value.get("method"))
        .and_then(|entry| entry.as_str())
        .is_some_and(|method| method.ends_with(".stream.open"))
}

fn h2_window_bytes(max_message_bytes: usize) -> u32 {
    u32::try_from(max_message_bytes).unwrap_or(u32::MAX)
}

fn configure_h2_client_windows(builder: &mut client::Builder, max_message_bytes: usize) {
    let window = h2_window_bytes(max_message_bytes);
    builder.initial_window_size(window);
    builder.initial_connection_window_size(window);
}

fn configure_h2_server_windows(builder: &mut server::Builder, max_message_bytes: usize) {
    let window = h2_window_bytes(max_message_bytes);
    builder.initial_window_size(window);
    builder.initial_connection_window_size(window);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{duplex, AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn read_http_request_rejects_content_length_over_bridge_cap() {
        let oversized = DEFAULT_MAX_BUFFERED_MESSAGE_BYTES + 1023;
        let request =
            format!("POST /rpc HTTP/1.1\r\nHost: localhost\r\nContent-Length: {oversized}\r\n\r\n");
        let (mut writer, reader) = duplex(1024);
        let writer_task = tokio::spawn(async move {
            writer.write_all(request.as_bytes()).await?;
            writer.shutdown().await
        });

        let mut reader = BufReader::new(reader);
        let err = read_http_request(&mut reader, DEFAULT_MAX_BUFFERED_MESSAGE_BYTES)
            .await
            .expect_err("oversized HTTP body should be rejected");
        assert!(err
            .to_string()
            .contains("HTTP body exceeds buffered bridge cap"));

        writer_task
            .await
            .expect("writer task should finish")
            .expect("writer should succeed");
    }

    #[tokio::test]
    async fn read_line_message_with_cap_rejects_oversized_messages() {
        let (mut writer, reader) = duplex(64);
        let writer_task = tokio::spawn(async move {
            writer.write_all(b"abcdef").await?;
            writer.shutdown().await
        });

        let mut reader = BufReader::new(reader);
        let mut buffer = Vec::new();
        let err = read_line_message_with_cap(&mut reader, &mut buffer, 5)
            .await
            .expect_err("oversized line should be rejected");
        assert!(err
            .to_string()
            .contains("message exceeds buffered bridge cap"));

        writer_task
            .await
            .expect("writer task should finish")
            .expect("writer should succeed");
    }

    #[tokio::test]
    async fn read_http_request_respects_custom_bridge_cap() {
        let body = "0123456789012345678901234567890123456789";
        let request = format!(
            "POST /rpc HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let (mut writer, reader) = duplex(128);
        let writer_task = tokio::spawn(async move {
            writer.write_all(request.as_bytes()).await?;
            writer.shutdown().await
        });

        let mut reader = BufReader::new(reader);
        let err = read_http_request(&mut reader, 32)
            .await
            .expect_err("custom cap should reject oversized HTTP body");
        assert!(err
            .to_string()
            .contains("HTTP body exceeds buffered bridge cap of 32 bytes"));

        writer_task
            .await
            .expect("writer task should finish")
            .expect("writer should succeed");
    }

    #[test]
    fn parse_h2_client_accepts_tls_boolean_and_trust_flags() {
        let command = parse_args_from(
            vec![
                "h2-client".to_string(),
                "--host".to_string(),
                "mux.example.com".to_string(),
                "--port".to_string(),
                "9443".to_string(),
                "--path".to_string(),
                "/rpc".to_string(),
                "--tls".to_string(),
                "--tls-ca-file".to_string(),
                "/tmp/root.crt".to_string(),
                "--tls-server-name".to_string(),
                "rpc.example.com".to_string(),
                "--tls-sha256".to_string(),
                "deadbeef".to_string(),
            ]
            .into_iter(),
        )
        .expect("bridge args should parse");

        match command {
            Command::H2Client(args) => {
                assert!(args.tls);
                assert_eq!(args.host, "mux.example.com");
                assert_eq!(args.port, 9443);
                assert_eq!(args.path, "/rpc");
                assert_eq!(args.tls_ca_file.as_deref(), Some("/tmp/root.crt"));
                assert_eq!(args.tls_server_name.as_deref(), Some("rpc.example.com"));
                assert_eq!(args.tls_sha256.as_deref(), Some("deadbeef"));
            }
            other => panic!("expected H2Client, got {other:?}"),
        }
    }

    #[test]
    fn parse_h3wt_client_accepts_trust_flags() {
        let command = parse_args_from(
            vec![
                "h3wt-client".to_string(),
                "--host".to_string(),
                "mux.example.com".to_string(),
                "--port".to_string(),
                "9443".to_string(),
                "--path".to_string(),
                "/mux".to_string(),
                "--sha256".to_string(),
                "deadbeef".to_string(),
                "--tls-ca-file".to_string(),
                "/tmp/root.crt".to_string(),
                "--tls-server-name".to_string(),
                "rpc.example.com".to_string(),
            ]
            .into_iter(),
        )
        .expect("bridge args should parse");

        match command {
            Command::H3wtClient(args) => {
                assert_eq!(args.host, "mux.example.com");
                assert_eq!(args.port, 9443);
                assert_eq!(args.path, "/mux");
                assert_eq!(args.sha256.as_deref(), Some("deadbeef"));
                assert_eq!(args.tls_ca_file.as_deref(), Some("/tmp/root.crt"));
                assert_eq!(args.tls_server_name.as_deref(), Some("rpc.example.com"));
            }
            other => panic!("expected H3wtClient, got {other:?}"),
        }
    }

    #[test]
    fn classify_upstream_lane_key_uses_envelope_payload_target() {
        let request = br#"{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"debug.sleep","params":{"ms":50}}"#;
        let envelope = format!(
            r#"{{"conversationId":"c-1","requestId":1,"target":{{"documentPath":"/demo"}},"kind":"rpc","payload":{}}}"#,
            std::str::from_utf8(request).expect("request should be utf8"),
        );

        assert_eq!(
            classify_upstream_lane_key(envelope.as_bytes()),
            UpstreamLaneKey::Document("/demo".to_string())
        );
    }

    #[test]
    fn classify_upstream_lane_key_keeps_root_only_requests_on_root_lane() {
        let request = br#"{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"session.create","params":{"sessionName":"demo"}}"#;
        let envelope = format!(
            r#"{{"conversationId":"c-1","requestId":1,"target":{{"documentPath":"/demo"}},"kind":"rpc","payload":{}}}"#,
            std::str::from_utf8(request).expect("request should be utf8"),
        );

        assert_eq!(
            classify_upstream_lane_key(envelope.as_bytes()),
            UpstreamLaneKey::Root
        );
    }
}
