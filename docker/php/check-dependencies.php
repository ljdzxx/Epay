<?php

// Standalone dependency check: no application bootstrap, database or API calls.
if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

error_reporting(E_ALL);
set_error_handler(static function ($severity, $message, $file, $line) {
    if (error_reporting() & $severity) {
        throw new ErrorException($message, 0, $severity, $file, $line);
    }
    return false;
});

function checkDependency($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

try {
    foreach (['gmp', 'bcmath', 'openssl', 'curl', 'mbstring', 'libxml', 'SimpleXML'] as $extension) {
        checkDependency(extension_loaded($extension), 'Missing extension: ' . $extension);
    }

    $vendorDir = $argv[1] ?? dirname(__DIR__, 2) . '/includes/vendor';
    require $vendorDir . '/autoload.php';

    foreach ([
        Alipay\AlipayService::class,
        Alipay\AlipayTradeService::class,
        Alipay\Aop\AlipayRequest::class,
        WeChatPay\PaymentService::class,
        WeChatPay\V3\PaymentService::class,
        WeChatPay\V3\TransferService::class,
        QQPay\PaymentService::class,
        Rtgm\sm\RtSm2::class,
        Rtgm\sm\RtSm3::class,
        Rtgm\sm\RtSm4::class,
    ] as $class) {
        checkDependency(class_exists($class), 'Class could not be loaded: ' . $class);
    }

    $request = new Alipay\Aop\AlipayRequest();
    $request->setOtherParams(['offline_check' => 'first']);
    $request->setOtherParams(['offline_check' => 'second', 'check_only' => 'yes']);
    checkDependency(
        $request->getOtherParams() === ['offline_check' => 'second', 'check_only' => 'yes'],
        'Alipay request parameter handling failed'
    );

    $sm3 = new Rtgm\sm\RtSm3();
    checkDependency(
        $sm3->digest('abc') === '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
        'SM3 known-answer check failed'
    );

    // Ephemeral local data only. No merchant keys or real payment data are used.
    $message = 'epay offline dependency compatibility check';
    $key = random_bytes(16);
    $iv = random_bytes(16);
    $sm4 = new Rtgm\sm\RtSm4($key);
    foreach (['sm4-cbc', 'sm4-ecb'] as $cipher) {
        $cipherIv = $cipher === 'sm4-ecb' ? '' : $iv;
        $encrypted = $sm4->encrypt($message, $cipher, $cipherIv, 'base64');
        checkDependency(
            $sm4->decrypt($encrypted, $cipher, $cipherIv, 'base64') === $message,
            $cipher . ' round-trip failed'
        );
        checkDependency(
            $encrypted === openssl_encrypt($message, $cipher, $key, 0, $cipherIv),
            $cipher . ' OpenSSL interoperability failed'
        );
    }

    $sm2 = new Rtgm\sm\RtSm2('base64', false);
    [$privateKey, $publicKey] = $sm2->generatekey();
    $signature = $sm2->doSign($message, $privateKey);
    checkDependency($sm2->verifySign($message, $signature, $publicKey), 'SM2 signature round-trip failed');
    $encrypted = $sm2->doEncrypt($message, $publicKey);
    checkDependency($sm2->doDecrypt($encrypted, $privateKey) === $message, 'SM2 encryption round-trip failed');

    echo 'Dependency compatibility checks OK', PHP_EOL;
} catch (Throwable $error) {
    fwrite(STDERR, 'Dependency check failed: ' . $error->getMessage() . PHP_EOL);
    exit(1);
}
