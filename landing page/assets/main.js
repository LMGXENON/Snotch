
async function loadPrompterText() {
    const linesEl = document.getElementById('notch-lines');
    let lines = [];
    // Try multiple candidate locations for the prompter file (relative and absolute)
    const candidatePaths = [
        'assets/prompter.txt',
        '/assets/prompter.txt',
        'prompter.txt'
    ];
    let text = null;
    for (const p of candidatePaths) {
        try {
            const resp = await fetch(p, { cache: 'no-cache' });
            if (!resp.ok) continue;
            text = await resp.text();
            break;
        } catch (err) {
            // ignore and try next path
        }
    }
    if (text) {
        // strip BOM and normalize CRLF to LF
        text = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
        lines = text.split('\n');
    } else {
        console.error('Failed to load prompter text from', candidatePaths);
        lines = ["Snotch", "Your discreet", "notch prompter"];
    }
    linesEl.style.animation = 'none';
    linesEl.style.transform = 'translateY(0px)';
    linesEl.style.animationPlayState = 'running';
    linesEl.innerHTML = '';
    const buildGroup = () => {
        const frag = document.createDocumentFragment();
        lines.forEach(text => {
            const line = document.createElement('div');
            line.textContent = text.trim() ? text : '\u00A0';
            frag.appendChild(line);
        });
        return frag;
    };
    linesEl.appendChild(buildGroup());
    linesEl.appendChild(buildGroup());
    const fontsReady = document.fonts && typeof document.fonts.ready?.then === 'function' ?
        document.fonts.ready :
        Promise.resolve();
    fontsReady.then(() => {
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                const groupSize = lines.length;
                const firstChild = linesEl.children[0];
                const firstChildOfSecondGroup = linesEl.children[groupSize];
                if (firstChild && firstChildOfSecondGroup) {
                    const distance = Math.round(firstChildOfSecondGroup.offsetTop - firstChild.offsetTop);
                    const speed = 24;
                    const duration = distance / speed;
                    linesEl.style.setProperty('--scroll-height', `${distance}px`);
                    linesEl.style.setProperty('--scroll-duration', `${duration}s`);
                    linesEl.style.animation = 'none';
                    void linesEl.offsetHeight;
                    linesEl.style.transform = 'translateY(0px)';
                    linesEl.style.animation = `scroll-up ${duration}s linear 0.3s infinite`;
                    linesEl.style.animationPlayState = 'running';
                }
            });
        });
    });
}

function initNotchPrompter() {
    const container = document.getElementById('notch-prompter');
    const linesEl = document.getElementById('notch-lines');
    let isPaused = false;
    let pausedTransform = null;
    let animationDuration = null;
    let scrollHeight = null;

    function getCurrentTransform() {
        const computed = window.getComputedStyle(linesEl);
        const transform = computed.transform || computed.webkitTransform;
        if (transform === 'none' || !transform) return 0;
        const matrixMatch = transform.match(/matrix\(([^)]+)\)|matrix3d\(([^)]+)\)/);
        if (matrixMatch) {
            const values = matrixMatch[1] || matrixMatch[2];
            if (values) {
                const nums = values.split(',').map(v => parseFloat(v.trim()));
                if (nums.length === 6) {
                    return nums[5];
                } else if (nums.length === 16) {
                    return nums[13];
                }
            }
        }
        return 0;
    }
    container.addEventListener('mouseenter', () => {
        const computed = window.getComputedStyle(linesEl);
        const animationName = computed.animationName || computed.webkitAnimationName;
        if (animationName === 'none' || !animationName) {
            isPaused = false;
        }
        if (isPaused) return;
        animationDuration = parseFloat(computed.getPropertyValue('--scroll-duration')) || 10;
        scrollHeight = parseFloat(computed.getPropertyValue('--scroll-height')) || 0;
        if (scrollHeight === 0 || !animationDuration) {
            linesEl.style.animationPlayState = 'paused';
            isPaused = true;
            return;
        }
        pausedTransform = getCurrentTransform();
        linesEl.style.animation = 'none';
        linesEl.style.transform = `translateY(${pausedTransform}px)`;
        isPaused = true;
    });
    container.addEventListener('mouseleave', () => {
        if (!isPaused) return;
        if (scrollHeight === 0 || !animationDuration) {
            linesEl.style.animationPlayState = 'running';
            isPaused = false;
            return;
        }
        const currentOffset = Math.abs(pausedTransform);
        const normalizedOffset = currentOffset % scrollHeight;
        const progress = normalizedOffset / scrollHeight;
        const delay = -(progress * animationDuration);
        requestAnimationFrame(() => {
            linesEl.style.transform = '';
            linesEl.style.animation = `scroll-up ${animationDuration}s linear ${delay}s infinite`;
        });
        isPaused = false;
        pausedTransform = null;
    });
    loadPrompterText();
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initNotchPrompter);
} else {
    initNotchPrompter();
}

function initMobileVideo() {
    const mv = document.getElementById('mobile-video');
    if (!mv) return;
    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                mv.play().catch(() => {});
            } else {
                mv.pause();
            }
        });
    }, {
        threshold: 0.4
    });
    observer.observe(mv);
    mv.addEventListener('click', () => {
        if (mv.muted) {
            mv.muted = false;
        } else {
            mv.muted = true;
        }
    });
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initMobileVideo);
} else {
    initMobileVideo();
}

function initVideo() {
    const video = document.getElementById('demo-video');
    const container = document.getElementById('pip-video-container');
    const sentinel = document.getElementById('pip-sentinel');
    if (!video || !container) return;
    const isMobile = window.matchMedia('(max-width: 768px)').matches;
    if (isMobile) return;

    function showPip() {
        container.style.opacity = '1';
        container.style.transform = 'translateY(0)';
        container.style.pointerEvents = 'auto';
        video.play().catch(() => {});
    }

    function hidePip() {
        container.style.opacity = '0';
        container.style.transform = 'translateY(16px)';
        container.style.pointerEvents = 'none';
        video.pause();
    }
    var pipAllowed = true;
    const startPip = () => {
        if (pipAllowed) showPip();
    };
    if (document.readyState === 'complete') {
        setTimeout(startPip, 2500);
    } else {
        window.addEventListener('load', () => setTimeout(startPip, 2500), {
            once: true
        });
    }
    if (sentinel) {
        const sentinelObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (!entry.isIntersecting && entry.boundingClientRect.top < 0) {
                    pipAllowed = false;
                    hidePip();
                } else {
                    pipAllowed = true;
                    showPip();
                }
            });
        }, {
            threshold: 0
        });
        sentinelObserver.observe(sentinel);
    }
    const closeBtn = document.getElementById('pip-close-btn');
    container.addEventListener('click', (e) => {
        e.preventDefault();
        if (e.target === closeBtn || closeBtn.contains(e.target)) return;
        video.muted = false;
        const req = container.requestFullscreen || container.webkitRequestFullscreen || container.mozRequestFullScreen;
        if (req) req.call(container).then(() => {
            video.play().catch(() => {});
        }).catch(() => {});
        document.addEventListener('fullscreenchange', function onExit() {
            if (!document.fullscreenElement) {
                video.muted = true;
                video.play().catch(() => {});
                document.removeEventListener('fullscreenchange', onExit);
            }
        });
    });
    if (closeBtn) {
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (document.exitFullscreen) document.exitFullscreen();
            else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
        });
    }
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initVideo);
} else {
    initVideo();
}

function initPrompterScroll() {
    const headerWrapper = document.getElementById('header-wrapper');
    if (!headerWrapper) {
        console.error('Header wrapper not found');
        return;
    }
    const scrollThreshold = 100;
    const scrollArrow = document.getElementById('scroll-arrow');

    function handleScroll() {
        const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
        if (scrollTop > scrollThreshold) {
            headerWrapper.classList.add('is-hidden');
            if (scrollArrow) scrollArrow.style.opacity = '0';
        } else {
            headerWrapper.classList.remove('is-hidden');
            if (scrollArrow) scrollArrow.style.opacity = '1';
        }
    }
    headerWrapper.classList.add('no-anim');
    handleScroll();
    requestAnimationFrame(() => {
        headerWrapper.classList.remove('no-anim');
    });
    let ticking = false;
    window.addEventListener('scroll', () => {
        if (!ticking) {
            requestAnimationFrame(() => {
                handleScroll();
                ticking = false;
            });
            ticking = true;
        }
    });
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initPrompterScroll);
} else {
    initPrompterScroll();
}
let animationComplete = false;

function maintainScrollPosition() {
    if (!animationComplete && window.pageYOffset !== 0) {
        window.scrollTo(0, 0);
    }
}
window.scrollTo(0, 0);
const scrollCheckInterval = setInterval(() => {
    if (!animationComplete) {
        maintainScrollPosition();
    } else {
        clearInterval(scrollCheckInterval);
    }
}, 50);
setTimeout(() => {
    animationComplete = true;
    window.scrollTo(0, 0);
}, 1000);
window.addEventListener('load', () => {
    window.scrollTo(0, 0);
    requestAnimationFrame(() => {
        document.body.classList.add('ready');
    });
});

function trackEvent(name, params) {
    if (typeof window.gtag === 'function') {
        window.gtag('event', name, params || {});
    }
}

function initFaqAccordion() {
    const faqItems = document.querySelectorAll('.faq-item');
    faqItems.forEach(item => {
        const question = item.querySelector('.faq-question');
        const answer = item.querySelector('.faq-answer');
        const icon = item.querySelector('.faq-icon');
        question.addEventListener('click', () => {
            const isOpen = answer.style.maxHeight && answer.style.maxHeight !== '0px';
            faqItems.forEach(otherItem => {
                const otherAnswer = otherItem.querySelector('.faq-answer');
                const otherIcon = otherItem.querySelector('.faq-icon');
                otherAnswer.style.maxHeight = '0';
                otherIcon.style.transform = 'rotate(0deg)';
            });
            if (!isOpen) {
                answer.style.maxHeight = answer.scrollHeight + 'px';
                icon.style.transform = 'rotate(180deg)';
            }
        });
    });
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initFaqAccordion);
} else {
    initFaqAccordion();
}
(function() {
    var roles = ['business', 'coaching', 'content', 'presentations', 'pitches', 'webinars'];
    var el = document.getElementById('role-cycle');
    if (!el) return;
    var i = 0;
    setInterval(function() {
        el.style.opacity = '0';
        setTimeout(function() {
            i = (i + 1) % roles.length;
            el.textContent = roles[i];
            el.style.opacity = '1';
        }, 400);
    }, 2200);
})();
(function() {
    var track = document.getElementById('hiw-track');
    var viewport = document.getElementById('hiw-viewport');
    if (!track || !viewport) return;

    function isMobile() {
        return window.innerWidth <= 768;
    }
    if (isMobile()) return;
    var cards = track.querySelectorAll('.hiw-card');
    var total = cards.length;
    var current = 0;
    var autoTimer = null;
    var cardWidth = 0.62;

    function goTo(idx) {
        if (idx < 0) idx = total - 1;
        if (idx >= total) idx = 0;
        current = idx;
        var offset = idx * cardWidth * 100;
        var center = (100 - cardWidth * 100) / 2;
        track.style.transform = 'translateX(' + (-offset + center) + '%)';
        for (var c = 0; c < cards.length; c++) {
            cards[c].style.opacity = '1';
            cards[c].style.transform = 'scale(1)';
        }
    }

    function startAuto() {
        stopAuto();
        autoTimer = setInterval(function() {
            goTo(current + 1);
        }, 4000);
    }

    function stopAuto() {
        if (autoTimer) {
            clearInterval(autoTimer);
            autoTimer = null;
        }
    }
    var startX = 0,
        diffX = 0,
        dragging = false;
    viewport.addEventListener('mousedown', function(e) {
        startX = e.clientX;
        diffX = 0;
        dragging = true;
        viewport.style.cursor = 'grabbing';
    });
    window.addEventListener('mousemove', function(e) {
        if (dragging) diffX = e.clientX - startX;
    });
    window.addEventListener('mouseup', function() {
        if (!dragging) return;
        dragging = false;
        viewport.style.cursor = 'grab';
        if (Math.abs(diffX) > 60) {
            stopAuto();
            if (diffX < 0) goTo(current + 1);
            else goTo(current - 1);
            startAuto();
        }
    });
    viewport.addEventListener('touchstart', function(e) {
        startX = e.touches[0].clientX;
        diffX = 0;
        stopAuto();
    }, {
        passive: true
    });
    viewport.addEventListener('touchmove', function(e) {
        diffX = e.touches[0].clientX - startX;
    }, {
        passive: true
    });
    viewport.addEventListener('touchend', function() {
        if (Math.abs(diffX) > 50) {
            if (diffX < 0) goTo(current + 1);
            else goTo(current - 1);
        }
        startAuto();
    });
    for (var c = 0; c < cards.length; c++) {
        cards[c].addEventListener('click', (function(idx) {
            return function() {
                if (idx !== current) {
                    stopAuto();
                    goTo(idx);
                    startAuto();
                }
            };
        })(c));
    }
    goTo(0);
    var hiwSection = document.getElementById('how-it-works');
    if (hiwSection) {
        var hiwObserver = new IntersectionObserver(function(entries) {
            entries.forEach(function(entry) {
                if (entry.isIntersecting) {
                    startAuto();
                } else {
                    stopAuto();
                }
            });
        }, {
            threshold: 0.2
        });
        hiwObserver.observe(hiwSection);
    }
})();

(function() {
    var btn = document.getElementById('features-toggle');
    var extra = document.getElementById('features-extra');
    var label = document.getElementById('features-toggle-label');
    var icon = document.getElementById('features-toggle-icon');
    if (!btn || !extra) return;
    var expanded = false;
    btn.addEventListener('click', function() {
        expanded = !expanded;
        extra.style.display = expanded ? 'contents' : 'none';
        label.textContent = expanded ? 'Show less' : 'See all features';
        icon.style.transform = expanded ? 'rotate(180deg)' : '';
    });
})();