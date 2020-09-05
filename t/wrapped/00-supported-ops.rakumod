use IO::URing;
use IO::URing::Raw;
use Test;

plan(:skip-all<<Must be on Linux >= 5.6>>) unless $*KERNEL ~~ "linux" && Version.new($*KERNEL.release) ~~ v5.6+;
plan 4;

my %supported-ops = IO::URing.supported-ops;

ok %supported-ops, <Can get hash of supported ops>;

ok %supported-ops<IORING_OP_NOP>, <Supports OP_NOP>;

nok %supported-ops<IORING_OP_LAST>, <No entry for OP_LAST>;

ok %supported-ops<IORING_OP_EPOLL_CTL>, <Entry for OP_TEE exists>;

done-testing;
