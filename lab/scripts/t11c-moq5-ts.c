/* T11c harness: MPEG-TS through moq5's service tier.
 *
 *   t11c-moq5-ts send <url> <namespace> <track> [--draft N] [--hold] < file.ts
 *   t11c-moq5-ts recv <url> <namespace> [--draft N] [--seconds S] [--log objects.csv] > file.ts
 *
 * send publishes stdin as one MSFTS "unmodified-multiplex" track of 188-byte packets (the caller
 * paces it), dropping what is written before a subscriber arrives as a live source would; --hold
 * keeps the library default, which queues it until one does. Once subscribed, nothing is dropped
 * (BLOCK_TIMEOUT), and 10 s without progress ends the send. recv takes every track its catalog lists and writes each MPEG2TS object's payload in
 * the order the receiver releases them (Location order); --log adds one CSV row per object, with
 * its Location, delivery origin and the receiver's loss report. Both log the negotiated version,
 * track events and totals to stderr. Certificate verification is off: loopback rigs only.
 *
 * Built inside moq5's tree, beside examples/service, linking moq::service.
 */
#include <moq/endpoint.h>
#include <moq/media_receiver.h>
#include <moq/media_sender.h>
#include <moq/msf.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static uint64_t now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static size_t split_namespace(char *buf, moq_bytes_t *parts, size_t max)
{
    size_t n = 0;
    char *p = buf;
    while (*p && n < max) {
        char *slash = strchr(p, '/');
        if (slash)
            *slash = '\0';
        parts[n].data = (const uint8_t *)p;
        parts[n].len = strlen(p);
        n++;
        if (!slash)
            break;
        p = slash + 1;
    }
    return n;
}

static moq_endpoint_t *connect_to(const char *url, int draft)
{
    static moq_version_t pinned;
    moq_endpoint_cfg_t ec;
    moq_endpoint_cfg_init_sized(&ec, sizeof(ec));
    ec.url.data = (const uint8_t *)url;
    ec.url.len = strlen(url);
    ec.insecure_skip_verify = true;
    if (draft != 0) {
        pinned = (moq_version_t)draft;
        ec.versions.struct_size = sizeof(moq_version_offer_t);
        ec.versions.policy = MOQ_VERSION_POLICY_EXACT;
        ec.versions.versions = &pinned;
        ec.versions.version_count = 1;
    }
    moq_endpoint_t *ep = NULL;
    moq_result_t rc = moq_endpoint_connect(&ec, &ep);
    if (rc != MOQ_OK) {
        fprintf(stderr, "connect failed: %d (%s)\n", (int)rc, moq_strerror(rc));
        return NULL;
    }
    return ep;
}

static int do_send(moq_endpoint_t *ep, moq_bytes_t *ns, size_t ns_count, const char *track,
                   bool hold)
{
    moq_media_sender_cfg_t cfg;
    moq_media_sender_cfg_init_live_sized(&cfg, sizeof(cfg));
    cfg.endpoint = NULL;
    cfg.namespace_.parts = ns;
    cfg.namespace_.count = ns_count;
    cfg.backpressure = MOQ_MEDIA_SEND_BP_BLOCK_TIMEOUT;
    cfg.drop_without_demand = !hold;
    moq_media_sender_t *s = NULL;
    moq_result_t rc = moq_media_sender_attach(ep, &cfg, &s);
    if (rc != MOQ_OK) {
        fprintf(stderr, "sender attach failed: %d\n", (int)rc);
        return 1;
    }

    moq_msf_mpeg2ts_t rec;
    moq_msf_mpeg2ts_init(&rec);
    rec.has_mode = true;
    rec.mode = MOQ_MSF_MPEG2TS_MODE_UNMODIFIED_MULTIPLEX;
    rec.has_packet_size = true;
    rec.packet_size = 188;
    moq_msf_track_ext_t ext = { .kind = MOQ_MSF_EXT_MPEG2TS, .u = { .mpeg2ts = &rec } };
    moq_media_track_cfg_t tc;
    moq_media_track_cfg_init(&tc);
    tc.name.data = (const uint8_t *)track;
    tc.name.len = strlen(track);
    tc.media_type = MOQ_MEDIA_TYPE_VIDEO;
    tc.packaging = MOQ_MEDIA_PACKAGING_MPEG2TS;
    tc.bitrate = 10000000;
    tc.is_live = true;
    tc.extensions = &ext;
    tc.extension_count = 1;
    moq_media_track_t *t = NULL;
    rc = moq_media_sender_add_track(s, &tc, &t);
    if (rc != MOQ_OK) {
        fprintf(stderr, "add_track failed: %d\n", (int)rc);
        moq_media_sender_destroy(s);
        return 1;
    }

    static uint8_t buf[188 * 64];
    unsigned long long total = 0;
    int status = 0;
    uint64_t progress = now_us();
    while (!g_stop) {
        size_t got = fread(buf, 1, sizeof(buf), stdin);
        if (got == 0)
            break;
        size_t off = 0;
        while (off < got && !g_stop) {
            moq_media_send_mpeg2ts_t in;
            memset(&in, 0, sizeof(in));
            in.struct_size = sizeof(in);
            in.data = (moq_bytes_t){ buf + off, got - off };
            size_t consumed = 0;
            moq_result_t wr = moq_media_sender_write_mpeg2ts(s, t, &in, &consumed);
            off += consumed;
            if (wr == MOQ_ERR_WOULD_BLOCK) {
                if (now_us() - progress > 10000000u) {
                    fprintf(stderr, "stalled: no progress for 10 s\n");
                    status = 1;
                    g_stop = 1;
                    break;
                }
                (void)moq_media_sender_wait(s, 100000);
                continue;
            }
            progress = now_us();
            if (wr != MOQ_OK) {
                fprintf(stderr, "write_mpeg2ts failed: %d\n", (int)wr);
                status = 1;
                g_stop = 1;
            }
        }
        total += got;
    }

    /* Objects a short write held back go out on empty calls, then the track ends. */
    for (int i = 0; i < 100; i++) {
        moq_media_sender_track_stats_t st;
        if (moq_media_sender_get_track_stats(s, t, &st, sizeof(st)) != MOQ_OK ||
            st.mpeg2ts_objects_parked == 0)
            break;
        moq_media_send_mpeg2ts_t in;
        memset(&in, 0, sizeof(in));
        in.struct_size = sizeof(in);
        size_t consumed = 0;
        (void)moq_media_sender_write_mpeg2ts(s, t, &in, &consumed);
        (void)moq_media_sender_wait(s, 100000);
    }
    for (int i = 0; i < 100 && moq_media_sender_end_track(s, t) == MOQ_ERR_WOULD_BLOCK; i++)
        (void)moq_media_sender_wait(s, 100000);
    (void)moq_endpoint_drain(ep, 5000000);
    fprintf(stderr, "sent %llu bytes\n", total);
    moq_media_sender_destroy(s);
    return status;
}

static int do_recv(moq_endpoint_t *ep, moq_bytes_t *ns, size_t ns_count, double seconds,
                   FILE *log)
{
    moq_media_receiver_cfg_t cfg;
    moq_media_receiver_cfg_init_live_sized(&cfg, sizeof(cfg));
    cfg.endpoint = NULL;
    cfg.namespace_.parts = ns;
    cfg.namespace_.count = ns_count;
    cfg.auto_subscribe = true;
    cfg.mpeg2ts_strip_prefix = true;
    moq_media_receiver_t *rx = NULL;
    moq_result_t rc = moq_media_receiver_attach(ep, &cfg, &rx);
    if (rc != MOQ_OK) {
        fprintf(stderr, "receiver attach failed: %d\n", (int)rc);
        return 1;
    }

    static char out[1 << 20];
    setvbuf(stdout, out, _IOFBF, sizeof(out));
    uint64_t end = seconds > 0 ? now_us() + (uint64_t)(seconds * 1e6) : 0;
    unsigned long long objects = 0, bytes = 0, other = 0;
    int status = 0;
    while (!g_stop && (end == 0 || now_us() < end)) {
        moq_media_track_event_t tev;
        while (moq_media_receiver_poll_track(rx, &tev, sizeof(tev)) == MOQ_OK) {
            fprintf(stderr, "track event %d", (int)tev.kind);
            if (tev.desc)
                fprintf(stderr, " name=%.*s", (int)tev.desc->name.len,
                        (const char *)tev.desc->name.data);
            fputc('\n', stderr);
        }
        moq_media_object_t obj;
        while (moq_media_receiver_poll_object(rx, &obj, sizeof(obj)) == MOQ_OK) {
            if (log && obj.struct_size == sizeof(obj))
                fprintf(log, "%llu,%llu,%llu,%zu,%u,%llu,%d,%d,%llu,%llu,%d,%d\n",
                        (unsigned long long)now_us(), (unsigned long long)obj.group_id,
                        (unsigned long long)obj.object_id, obj.payload.len,
                        (unsigned)obj.delivery_origin,
                        (unsigned long long)obj.initiating_request_id, (int)obj.end_of_group,
                        (int)obj.gap, (unsigned long long)obj.gap_group,
                        (unsigned long long)obj.gap_object, (int)obj.gap_tail_unknown,
                        (int)obj.discontinuous);
            if (obj.packaging == MOQ_MEDIA_PACKAGING_MPEG2TS && obj.payload.len > 0) {
                fwrite(obj.payload.data, 1, obj.payload.len, stdout);
                objects++;
                bytes += obj.payload.len;
            } else {
                other++;
            }
            moq_media_object_cleanup(&obj);
        }
        if (moq_media_receiver_is_fatal(rx)) {
            fprintf(stderr, "receiver fatal: %d\n", (int)moq_media_receiver_fatal_code(rx));
            status = 1;
            break;
        }
        (void)moq_media_receiver_wait(rx, 50000);
    }
    fflush(stdout);
    if (log)
        fclose(log);
    fprintf(stderr, "received %llu TS objects, %llu bytes; %llu other objects\n", objects, bytes,
            other);
    moq_media_receiver_destroy(rx);
    return status;
}

int main(int argc, char **argv)
{
    if (argc < 4 || (strcmp(argv[1], "send") != 0 && strcmp(argv[1], "recv") != 0)) {
        fprintf(stderr, "usage: %s send <url> <namespace> <track> [--draft N] [--hold] < in.ts\n"
                        "       %s recv <url> <namespace> [--draft N] [--seconds S] [--log f.csv]"
                        " > out.ts\n",
                argv[0], argv[0]);
        return 2;
    }
    bool send = strcmp(argv[1], "send") == 0;
    const char *url = argv[2];
    char nsbuf[256];
    snprintf(nsbuf, sizeof(nsbuf), "%s", argv[3]);
    moq_bytes_t ns[32];
    size_t ns_count = split_namespace(nsbuf, ns, 32);
    const char *track = "ts";
    int draft = 0;
    double seconds = 0;
    FILE *log = NULL;
    bool hold = false;
    int i = 4;
    if (send && argc > 4 && argv[4][0] != '-')
        track = argv[i++];
    for (; i < argc; i++) {
        if (strcmp(argv[i], "--draft") == 0 && i + 1 < argc)
            draft = atoi(argv[++i]);
        else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc)
            seconds = atof(argv[++i]);
        else if (strcmp(argv[i], "--hold") == 0 && send)
            hold = true;
        else if (strcmp(argv[i], "--log") == 0 && i + 1 < argc && !send) {
            log = fopen(argv[++i], "w");
            if (!log) {
                perror(argv[i]);
                return 2;
            }
            fprintf(log, "arrival_us,group,object,bytes,origin,request_id,end_of_group,gap,"
                         "gap_group,gap_object,gap_tail_unknown,discontinuous\n");
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    moq_endpoint_t *ep = connect_to(url, draft);
    if (!ep)
        return 1;
    int status = send ? do_send(ep, ns, ns_count, track, hold)
                      : do_recv(ep, ns, ns_count, seconds, log);
    fprintf(stderr, "negotiated version %d\n", (int)moq_endpoint_negotiated_version(ep));
    moq_endpoint_stop(ep);
    moq_endpoint_destroy(ep);
    return status;
}
