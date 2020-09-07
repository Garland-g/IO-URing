#include <liburing.h>

extern void io_uring_cqe_seen_wrapper(struct io_uring *ring,
				struct io_uring_cqe *cqe);
