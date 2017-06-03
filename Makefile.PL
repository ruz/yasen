use lib '.';
use inc::Module::Install;

all_from('lib/Yasen.pm');

requires
    'Promises' => '0.90',
    'Scalar::Util' => '0',
    'Async::ContextSwitcher' => '0.01',
    'Plack::Request' => '0',
    'JSON' => '0',
    'Digest::MD5' => '0',
;


WriteAll();
