/* T36 probe: one standalone FETCH or TRACK_STATUS over moq5's service tier, answer reported.
 *
 *   t36-probe <url> <namespace> <track> status [--draft N] [--timeout S]
 *   t36-probe <url> <namespace> <track> fetch --group G [--draft N] [--timeout S] [--out F]
 *
 * The URL carries the credential (?jwt=...). fetch asks for the whole of group G, and --out writes
 * the payloads it delivers, in arrival order, to F. The probe
 * prints one line of key=value pairs: the answer (ok, error, reset, cancelled, terminated,
 * timeout or closed), its code and reason, the Largest Location a TRACK_STATUS_OK reported,
 * and the objects and payload bytes a FETCH delivered, counted here at the client. No media
 * attachment is made, so the probe drains session events itself on the network thread.
 * Certificate verification is off: loopback rigs only.
 *
 * Built inside moq5's tree, beside examples/service, linking moq::service.
 */
#include <moq/endpoint.h>
#include <moq/rcbuf.h>
#include <moq/session.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct probe {
    bool fetch;
    moq_namespace_t ns;
    moq_bytes_t track;
    uint64_t group;
    moq_result_t start_rc;
    bool started, done;
    const char *result;
    unsigned long long code;
    char reason[256];
    bool has_largest;
    unsigned long long largest_group, largest_object, end_group, end_object;
    unsigned long long objects, bytes;
    FILE *out;
} probe_t;

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

static void finish(probe_t *p, const char *result, unsigned long long code, moq_bytes_t reason)
{
    p->result = result;
    p->code = code;
    size_t n = reason.len < sizeof(p->reason) - 1 ? reason.len : sizeof(p->reason) - 1;
    if (n)
        memcpy(p->reason, reason.data, n);
    p->reason[n] = '\0';
    p->done = true;
}

static moq_result_t task_start(moq_endpoint_t *ep, moq_session_t *s, uint64_t now, void *ctx)
{
    (void)ep;
    probe_t *p = ctx;
    if (!s)
        return MOQ_OK;
    if (p->fetch) {
        moq_fetch_cfg_t fc;
        moq_fetch_cfg_init_sized(&fc, sizeof(fc));
        fc.track_namespace = p->ns;
        fc.track_name = p->track;
        fc.start_group = p->group;
        fc.start_object = 0;
        fc.end_group = p->group;
        fc.end_object = 0;
        moq_fetch_t h;
        p->start_rc = moq_session_fetch(s, &fc, now, &h);
    } else {
        moq_track_status_cfg_t tc;
        moq_track_status_cfg_init(&tc);
        tc.track_namespace = p->ns;
        tc.track_name = p->track;
        moq_track_status_handle_t h;
        p->start_rc = moq_session_track_status(s, &tc, now, &h);
    }
    p->started = true;
    return MOQ_OK;
}

static moq_result_t task_poll(moq_endpoint_t *ep, moq_session_t *s, uint64_t now, void *ctx)
{
    (void)ep;
    (void)now;
    probe_t *p = ctx;
    static moq_event_t ev[32];
    static const moq_bytes_t none = { NULL, 0 };
    if (!s)
        return MOQ_OK;
    size_t n;
    while ((n = moq_session_poll_events(s, ev, 32)) > 0) {
        for (size_t i = 0; i < n; i++) {
            moq_event_t *e = &ev[i];
            switch (e->kind) {
            case MOQ_EVENT_FETCH_OK:
                p->end_group = e->u.fetch_ok.end_group;
                p->end_object = e->u.fetch_ok.end_object;
                p->result = "ok";
                break;
            case MOQ_EVENT_FETCH_OBJECT:
                p->objects++;
                p->bytes += moq_rcbuf_len(e->u.fetch_object.payload);
                if (p->out && e->u.fetch_object.payload)
                    fwrite(moq_rcbuf_data(e->u.fetch_object.payload), 1,
                           moq_rcbuf_len(e->u.fetch_object.payload), p->out);
                break;
            case MOQ_EVENT_FETCH_COMPLETE:
                finish(p, "ok", 0, none);
                break;
            case MOQ_EVENT_FETCH_ERROR:
                finish(p, "error", e->u.fetch_error.error_code, e->u.fetch_error.reason);
                break;
            case MOQ_EVENT_FETCH_RESET:
                finish(p, p->result ? "ok-then-reset" : "reset", e->u.fetch_reset.error_code,
                       none);
                break;
            case MOQ_EVENT_FETCH_CANCELLED:
                finish(p, "cancelled", e->u.fetch_cancelled.stream_error_code, none);
                break;
            case MOQ_EVENT_TRACK_STATUS_OK:
                p->has_largest = e->u.track_status_ok.has_largest;
                p->largest_group = e->u.track_status_ok.largest_group;
                p->largest_object = e->u.track_status_ok.largest_object;
                finish(p, "ok", 0, none);
                break;
            case MOQ_EVENT_TRACK_STATUS_ERROR:
                finish(p, "error", e->u.track_status_error.error_code,
                       e->u.track_status_error.reason);
                break;
            case MOQ_EVENT_TRACK_STATUS_TERMINATED:
                finish(p, "terminated", e->u.track_status_terminated.cause, none);
                break;
            default:
                break;
            }
            moq_event_cleanup(e);
        }
    }
    return MOQ_OK;
}

int main(int argc, char **argv)
{
    if (argc < 5 || (strcmp(argv[4], "fetch") != 0 && strcmp(argv[4], "status") != 0)) {
        fprintf(stderr, "usage: %s <url> <namespace> <track> status|fetch [--group G]"
                        " [--draft N] [--timeout S]\n",
                argv[0]);
        return 2;
    }
    probe_t p;
    memset(&p, 0, sizeof(p));
    char nsbuf[256];
    snprintf(nsbuf, sizeof(nsbuf), "%s", argv[2]);
    moq_bytes_t parts[32];
    p.ns.parts = parts;
    p.ns.count = split_namespace(nsbuf, parts, 32);
    p.track = (moq_bytes_t){ (const uint8_t *)argv[3], strlen(argv[3]) };
    p.fetch = strcmp(argv[4], "fetch") == 0;
    bool has_group = false;
    int draft = 0;
    double timeout = 10;
    for (int i = 5; i < argc; i++) {
        if (strcmp(argv[i], "--group") == 0 && i + 1 < argc) {
            p.group = strtoull(argv[++i], NULL, 10);
            has_group = true;
        } else if (strcmp(argv[i], "--draft") == 0 && i + 1 < argc)
            draft = atoi(argv[++i]);
        else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc)
            timeout = atof(argv[++i]);
        else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            p.out = fopen(argv[++i], "wb");
            if (!p.out) {
                perror(argv[i]);
                return 2;
            }
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (p.fetch && !has_group) {
        fprintf(stderr, "fetch needs --group\n");
        return 2;
    }

    static moq_version_t pinned;
    moq_endpoint_cfg_t ec;
    moq_endpoint_cfg_init_sized(&ec, sizeof(ec));
    ec.url.data = (const uint8_t *)argv[1];
    ec.url.len = strlen(argv[1]);
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
        printf("mode=%s result=connect-failed rc=%d\n", argv[4], (int)rc);
        return 1;
    }

    uint64_t deadline = now_us() + (uint64_t)(timeout * 1e6);
    while (moq_endpoint_state(ep) == MOQ_ENDPOINT_CONNECTING && now_us() < deadline)
        (void)moq_endpoint_wait(ep, 50000);
    if (moq_endpoint_state(ep) == MOQ_ENDPOINT_ESTABLISHED &&
        moq_endpoint_post(ep, task_start, &p) == MOQ_OK) {
        while (!p.done && now_us() < deadline && !moq_endpoint_is_closed(ep)) {
            if (moq_endpoint_post(ep, task_poll, &p) != MOQ_OK)
                break;
            (void)moq_endpoint_wait(ep, 20000);
        }
    }

    moq_endpoint_terminal_t term;
    memset(&term, 0, sizeof(term));
    (void)moq_endpoint_get_terminal(ep, &term, sizeof(term));
    const char *result = p.done ? p.result
                         : moq_endpoint_is_closed(ep) ? "closed"
                         : p.result                    ? "ok-incomplete"
                                                       : "timeout";
    if (p.started && p.start_rc != MOQ_OK)
        result = "not-sent";
    printf("mode=%s result=%s code=%llu reason=\"%s\" largest=%s%llu:%llu end=%llu:%llu"
           " objects=%llu bytes=%llu version=%d start_rc=%d terminal=%d:%llu\n",
           argv[4], result, p.code, p.reason, p.has_largest ? "" : "none/", p.largest_group,
           p.largest_object, p.end_group, p.end_object, p.objects, p.bytes,
           (int)moq_endpoint_negotiated_version(ep), (int)p.start_rc, (int)term.reason,
           (unsigned long long)term.detail_code);
    moq_endpoint_stop(ep);
    moq_endpoint_destroy(ep);
    if (p.out)
        fclose(p.out);
    return 0;
}
