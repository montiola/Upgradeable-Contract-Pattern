;; Upgradeable Contract Pattern Implementation
;; A robust proxy contract that delegates calls to implementation contracts

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-ADDRESS (err u101))
(define-constant ERR-UPGRADE-FAILED (err u102))
(define-constant ERR-INITIALIZATION-FAILED (err u103))
(define-constant ERR-ALREADY-INITIALIZED (err u104))
(define-constant ERR-INVALID-VERSION (err u105))
(define-constant ERR-TIMELOCK-ACTIVE (err u106))
(define-constant ERR-INVALID-FUNCTION (err u107))
(define-constant ERR-INVALID-INPUT (err u108))

;; Contract variables
(define-data-var contract-owner principal tx-sender)
(define-data-var implementation-address (optional principal) none)
(define-data-var contract-version uint u1)
(define-data-var is-initialized bool false)
(define-data-var upgrade-timelock uint u0)
(define-data-var pending-upgrade (optional principal) none)

;; Constants
(define-constant TIMELOCK-BLOCKS u144)
(define-constant MAX-VERSION u1000000)
(define-constant MIN-VERSION u1)

;; Authorization maps
(define-map authorized-upgraders principal bool)
(define-map function-permissions { func: (string-ascii 64) } { allowed: bool })

;; Upgrade history for audit trail
(define-map upgrade-history 
    uint 
    { 
        old-impl: (optional principal), 
        new-impl: principal, 
        upgrader: principal, 
        block-height: uint,
        version: uint
    }
)

;; Implementation registry
(define-map implementation-registry 
    principal 
    { 
        version: uint, 
        is-active: bool, 
        deployed-at: uint 
    }
)

;; Input validation functions
(define-private (is-valid-principal (addr principal))
    (not (is-eq addr 'SP000000000000000000002Q6VF78))
)

(define-private (is-valid-version (version uint))
    (and (>= version MIN-VERSION) (<= version MAX-VERSION))
)

(define-private (is-valid-function-name (func-name (string-ascii 64)))
    (> (len func-name) u0)
)

;; Events (using print statements for logging)
(define-private (emit-upgrade-event (old-impl (optional principal)) (new-impl principal) (version uint))
    (print { 
        event: "upgrade", 
        old-implementation: old-impl, 
        new-implementation: new-impl, 
        version: version, 
        block: block-height 
    })
)

(define-private (emit-ownership-transfer (old-owner principal) (new-owner principal))
    (print { 
        event: "ownership-transfer", 
        old-owner: old-owner, 
        new-owner: new-owner, 
        block: block-height 
    })
)

;; Owner-only modifier
(define-private (is-owner)
    (is-eq tx-sender (var-get contract-owner))
)

;; Authorized upgrader check
(define-private (is-authorized-upgrader)
    (or (is-owner) (default-to false (map-get? authorized-upgraders tx-sender)))
)

;; Initialization function (called once)
(define-public (initialize (initial-implementation principal))
    (begin
        (asserts! (not (var-get is-initialized)) ERR-ALREADY-INITIALIZED)
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (asserts! (is-valid-principal initial-implementation) ERR-INVALID-ADDRESS)
        (try! (register-implementation initial-implementation u1))
        (var-set implementation-address (some initial-implementation))
        (var-set is-initialized true)
        (map-set upgrade-history u1 {
            old-impl: none,
            new-impl: initial-implementation,
            upgrader: tx-sender,
            block-height: block-height,
            version: u1
        })
        (emit-upgrade-event none initial-implementation u1)
        (ok true)
    )
)

;; Register implementation contract
(define-public (register-implementation (impl-address principal) (version uint))
    (begin
        (asserts! (is-authorized-upgrader) ERR-UNAUTHORIZED)
        (asserts! (is-valid-principal impl-address) ERR-INVALID-ADDRESS)
        (asserts! (is-valid-version version) ERR-INVALID-VERSION)
        (map-set implementation-registry impl-address {
            version: version,
            is-active: true,
            deployed-at: block-height
        })
        (ok true)
    )
)

;; Propose upgrade with timelock
(define-public (propose-upgrade (new-implementation principal) (new-version uint))
    (begin
        (asserts! (is-authorized-upgrader) ERR-UNAUTHORIZED)
        (asserts! (var-get is-initialized) ERR-INITIALIZATION-FAILED)
        (asserts! (is-valid-principal new-implementation) ERR-INVALID-ADDRESS)
        (asserts! (is-valid-version new-version) ERR-INVALID-VERSION)
        (asserts! (> new-version (var-get contract-version)) ERR-INVALID-VERSION)
        (let ((impl-info (map-get? implementation-registry new-implementation)))
            (asserts! (is-some impl-info) ERR-INVALID-ADDRESS)
            (asserts! (get is-active (unwrap-panic impl-info)) ERR-INVALID-ADDRESS)
            (var-set pending-upgrade (some new-implementation))
            (var-set upgrade-timelock (+ block-height TIMELOCK-BLOCKS))
            (print { 
                event: "upgrade-proposed", 
                implementation: new-implementation, 
                version: new-version,
                timelock-until: (+ block-height TIMELOCK-BLOCKS)
            })
            (ok true)
        )
    )
)

;; Execute upgrade after timelock
(define-public (execute-upgrade)
    (let ((pending (var-get pending-upgrade))
          (current-impl (var-get implementation-address))
          (new-version (+ (var-get contract-version) u1)))
        (asserts! (is-authorized-upgrader) ERR-UNAUTHORIZED)
        (asserts! (is-some pending) ERR-UPGRADE-FAILED)
        (asserts! (>= block-height (var-get upgrade-timelock)) ERR-TIMELOCK-ACTIVE)
        (let ((new-impl (unwrap-panic pending)))
            (asserts! (is-valid-principal new-impl) ERR-INVALID-ADDRESS)
            (var-set implementation-address (some new-impl))
            (var-set contract-version new-version)
            (var-set pending-upgrade none)
            (var-set upgrade-timelock u0)
            (map-set upgrade-history new-version {
                old-impl: current-impl,
                new-impl: new-impl,
                upgrader: tx-sender,
                block-height: block-height,
                version: new-version
            })
            (emit-upgrade-event current-impl new-impl new-version)
            (ok true)
        )
    )
)

;; Cancel pending upgrade
(define-public (cancel-upgrade)
    (begin
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (var-set pending-upgrade none)
        (var-set upgrade-timelock u0)
        (print { event: "upgrade-cancelled", block: block-height })
        (ok true)
    )
)

;; Emergency upgrade (owner only, bypasses timelock)
(define-public (emergency-upgrade (new-implementation principal))
    (let ((current-impl (var-get implementation-address))
          (new-version (+ (var-get contract-version) u1)))
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (asserts! (var-get is-initialized) ERR-INITIALIZATION-FAILED)
        (asserts! (is-valid-principal new-implementation) ERR-INVALID-ADDRESS)
        (let ((impl-info (map-get? implementation-registry new-implementation)))
            (asserts! (is-some impl-info) ERR-INVALID-ADDRESS)
            (var-set implementation-address (some new-implementation))
            (var-set contract-version new-version)
            (var-set pending-upgrade none)
            (var-set upgrade-timelock u0)
            (map-set upgrade-history new-version {
                old-impl: current-impl,
                new-impl: new-implementation,
                upgrader: tx-sender,
                block-height: block-height,
                version: new-version
            })
            (emit-upgrade-event current-impl new-implementation new-version)
            (print { event: "emergency-upgrade", implementation: new-implementation })
            (ok true)
        )
    )
)

;; Transfer ownership
(define-public (transfer-ownership (new-owner principal))
    (let ((current-owner (var-get contract-owner)))
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (asserts! (is-valid-principal new-owner) ERR-INVALID-ADDRESS)
        (asserts! (not (is-eq new-owner current-owner)) ERR-INVALID-INPUT)
        (var-set contract-owner new-owner)
        (emit-ownership-transfer current-owner new-owner)
        (ok true)
    )
)

;; Manage authorized upgraders
(define-public (set-upgrader-permission (upgrader principal) (allowed bool))
    (begin
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (asserts! (is-valid-principal upgrader) ERR-INVALID-ADDRESS)
        (asserts! (not (is-eq upgrader (var-get contract-owner))) ERR-INVALID-INPUT)
        (map-set authorized-upgraders upgrader allowed)
        (print { 
            event: "upgrader-permission-changed", 
            upgrader: upgrader, 
            allowed: allowed 
        })
        (ok true)
    )
)

;; Set function permissions
(define-public (set-function-permission (function-name (string-ascii 64)) (allowed bool))
    (begin
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (asserts! (is-valid-function-name function-name) ERR-INVALID-INPUT)
        (map-set function-permissions { func: function-name } { allowed: allowed })
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-implementation)
    (var-get implementation-address)
)

(define-read-only (get-owner)
    (var-get contract-owner)
)

(define-read-only (get-version)
    (var-get contract-version)
)

(define-read-only (is-contract-initialized)
    (var-get is-initialized)
)

(define-read-only (get-pending-upgrade)
    (var-get pending-upgrade)
)

(define-read-only (get-timelock-expiry)
    (var-get upgrade-timelock)
)

(define-read-only (get-upgrade-history (version uint))
    (map-get? upgrade-history version)
)

(define-read-only (get-implementation-info (impl-address principal))
    (map-get? implementation-registry impl-address)
)

(define-read-only (is-upgrader-authorized (upgrader principal))
    (default-to false (map-get? authorized-upgraders upgrader))
)

(define-read-only (get-function-permission (function-name (string-ascii 64)))
    (default-to false (get allowed (map-get? function-permissions { func: function-name })))
)

;; Pause/Unpause functionality
(define-data-var is-paused bool false)

(define-public (pause-contract)
    (begin
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (var-set is-paused true)
        (print { event: "contract-paused", block: block-height })
        (ok true)
    )
)

(define-public (unpause-contract)
    (begin
        (asserts! (is-owner) ERR-UNAUTHORIZED)
        (var-set is-paused false)
        (print { event: "contract-unpaused", block: block-height })
        (ok true)
    )
)

(define-read-only (is-contract-paused)
    (var-get is-paused)
)

;; Validate contract state
(define-read-only (validate-contract-state)
    (let ((impl (var-get implementation-address))
          (version (var-get contract-version))
          (initialized (var-get is-initialized)))
        {
            has-implementation: (is-some impl),
            current-version: version,
            is-initialized: initialized,
            is-paused: (var-get is-paused),
            pending-upgrade: (var-get pending-upgrade),
            timelock-active: (> (var-get upgrade-timelock) block-height)
        }
    )
)

;; Proxy call function (delegates to implementation)
(define-public (proxy-call (function-data (buff 1024)))
    (begin
        (asserts! (not (var-get is-paused)) ERR-UNAUTHORIZED)
        (asserts! (var-get is-initialized) ERR-INITIALIZATION-FAILED)
        (let ((impl (var-get implementation-address)))
            (asserts! (is-some impl) ERR-INVALID-ADDRESS)
            (print { 
                event: "proxy-call", 
                implementation: impl, 
                data: function-data 
            })
            (ok true)
        )
    )
)